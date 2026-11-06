defmodule AshCache.Changes.InvalidateCache do
  @moduledoc """
  Invalidates a resource's cached reads after a successful write by bumping
  the resource's cache version (see `AshCache.CacheVersion`).

  The bump runs in `after_transaction`, never `after_action`: a write that
  rolls back must leave the cache untouched, and reads running concurrently
  with the transaction keep caching under the old cache version — harmless,
  because the bump after commit makes those entries unreachable.

  Ash's `after_transaction` runs when Ash's own transaction ends. An app that
  wraps the write in an outer transaction can hold the bump until that outer
  transaction commits with `config :ash_cache, after_commit: {Module, :fun}`:
  the write then hands `fun` a zero-arity function from `after_action`, and
  `fun` must call it once the outermost transaction has committed, or drop it
  if it rolls back.
  """

  use Ash.Resource.Change

  alias AshCache.CacheVersion
  alias AshCache.RecacheAfterWrite

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    store = Keyword.fetch!(opts, :store)
    recaches = Keyword.get(opts, :recache_after_write, [])

    work_after_write = fn changeset, record ->
      fn ->
        bump(store, changeset.resource)
        recache_reads(changeset, record, recaches)
      end
    end

    case app_after_commit() do
      nil ->
        Ash.Changeset.after_transaction(changeset, fn changeset, result ->
          with {:ok, record} <- result, do: work_after_write.(changeset, record).()
          result
        end)

      {module, function} ->
        Ash.Changeset.after_action(changeset, fn changeset, record ->
          apply(module, function, [work_after_write.(changeset, record)])
          {:ok, record}
        end)
    end
  end

  # With the app holding work until its outermost commit, the hand-over happens
  # inside the write: an after_transaction hook here would itself run inside the
  # app's still-open transaction.
  defp app_after_commit do
    Process.get(:ash_cache_after_commit) || Application.get_env(:ash_cache, :after_commit)
  end

  # The store refused both writing and deleting the counter, so reads may
  # keep answering from entries cached before this write until their TTL.
  defp bump(store, resource) do
    with {:error, reason} <- CacheVersion.bump(store, resource) do
      Logger.warning("AshCache could not invalidate #{inspect(resource)}: #{inspect(reason)}")
    end
  end

  defp recache_reads(%{action: %{type: :destroy}}, _record, _recaches), do: :ok

  defp recache_reads(changeset, record, recaches) do
    Enum.each(recaches, fn recache ->
      case run_recache(changeset.resource, changeset.tenant, record, recache) do
        {:error, reason} -> log_recache_failure(changeset.resource, recache, reason)
        _recached -> :ok
      end
    end)
  end

  # The write has already committed, so this is nobody's failure to handle —
  # but a recache that keeps failing should be visible as more than latency.
  defp log_recache_failure(resource, %RecacheAfterWrite{read: read}, reason) do
    Logger.warning("AshCache could not recache #{inspect(resource)}.#{read}: #{inspect(reason)}")
  end

  defp run_recache(resource, tenant, record, %RecacheAfterWrite{
         read: read,
         arguments: argument_attributes,
         actor: actor_mfa
       }) do
    actor = recache_actor(actor_mfa)

    arguments =
      for {argument, attribute} <-
            RecacheAfterWrite.argument_sources(resource, read, argument_attributes),
          into: %{},
          do: {argument, Map.get(record, attribute)}

    resource
    |> Ash.Query.for_read(read, arguments, actor: actor, tenant: tenant)
    |> Ash.read(actor: actor, tenant: tenant)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp recache_actor(nil), do: nil
  defp recache_actor({module, function, args}), do: apply(module, function, args)

  # The change only registers an after_transaction hook, so it is safe under
  # atomic updates (Ash 3 defaults update actions to require_atomic? true).
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
