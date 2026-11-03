defmodule AshCache.Changes.InvalidateCache do
  @moduledoc """
  Invalidates a resource's cached reads after a successful write by bumping
  the resource's cache version (see `AshCache.CacheVersion`).

  The bump runs in `after_transaction`, never `after_action`: a write that
  rolls back must leave the cache untouched, and reads running concurrently
  with the transaction keep caching under the old cache version — harmless,
  because the bump after commit makes those entries unreachable.
  """

  use Ash.Resource.Change

  alias AshCache.CacheVersion
  alias AshCache.Refresh

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    store = Keyword.fetch!(opts, :store)
    refreshes = Keyword.get(opts, :refresh, [])

    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      case result do
        {:ok, record} ->
          bump(store, changeset.resource)
          refresh_reads(changeset, record, refreshes)

        _error ->
          :noop
      end

      result
    end)
  end

  # The store refused both writing and deleting the counter, so reads may
  # keep answering from entries cached before this write until their TTL.
  defp bump(store, resource) do
    with {:error, reason} <- CacheVersion.bump(store, resource) do
      Logger.warning("AshCache could not invalidate #{inspect(resource)}: #{inspect(reason)}")
    end
  end

  defp refresh_reads(%{action: %{type: :destroy}}, _record, _refreshes), do: :ok

  defp refresh_reads(changeset, record, refreshes) do
    Enum.each(refreshes, fn refresh ->
      case run_refresh(changeset.resource, changeset.tenant, record, refresh) do
        {:error, reason} -> log_refresh_failure(changeset.resource, refresh, reason)
        _refreshed -> :ok
      end
    end)
  end

  # The write has already committed, so this is nobody's failure to handle —
  # but a refresh that keeps failing should be visible as more than latency.
  defp log_refresh_failure(resource, %Refresh{read: read}, reason) do
    Logger.warning("AshCache could not refresh #{inspect(resource)}.#{read}: #{inspect(reason)}")
  end

  defp run_refresh(resource, tenant, record, %Refresh{
         read: read,
         arguments: argument_attributes,
         actor: actor_mfa
       }) do
    actor = refresh_actor(actor_mfa)

    arguments =
      Map.new(argument_attributes, fn {argument, attribute} ->
        {argument, Map.get(record, attribute)}
      end)

    resource
    |> Ash.Query.for_read(read, arguments, actor: actor, tenant: tenant)
    |> Ash.read(actor: actor, tenant: tenant)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp refresh_actor(nil), do: nil
  defp refresh_actor({module, function, args}), do: apply(module, function, args)

  # The change only registers an after_transaction hook, so it is safe under
  # atomic updates (Ash 3 defaults update actions to require_atomic? true).
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
