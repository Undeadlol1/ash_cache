defmodule AshCache.Changes.BumpGeneration do
  @moduledoc """
  Invalidates a resource's cached reads after a successful write by bumping
  the resource's cache generation (see `AshCache.Generation`).

  The bump runs in `after_transaction`, never `after_action`: a write that
  rolls back must leave the cache untouched, and reads running concurrently
  with the transaction keep caching under the old generation — harmless,
  because the bump after commit makes those entries unreachable.
  """

  use Ash.Resource.Change

  alias AshCache.Generation
  alias AshCache.Warm

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    store = Keyword.fetch!(opts, :store)
    warm_specs = Keyword.get(opts, :warm, [])

    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      case result do
        {:ok, record} ->
          bump(store, changeset.resource)
          warm(changeset, record, warm_specs)

        _error ->
          :noop
      end

      result
    end)
  end

  # The store refused both writing and deleting the counter, so reads may
  # keep answering from entries cached before this write until their TTL.
  defp bump(store, resource) do
    with {:error, reason} <- Generation.bump(store, resource) do
      Logger.warning("AshCache could not invalidate #{inspect(resource)}: #{inspect(reason)}")
    end
  end

  defp warm(%{action: %{type: :destroy}}, _record, _warm_specs), do: :ok

  defp warm(changeset, record, warm_specs) do
    Enum.each(warm_specs, fn spec ->
      case warm_one(changeset.resource, changeset.tenant, record, spec) do
        {:error, reason} -> log_warm_failure(changeset.resource, spec, reason)
        _warmed -> :ok
      end
    end)
  end

  # The write has already committed, so this is nobody's failure to handle —
  # but a warm that keeps failing should be visible as more than latency.
  defp log_warm_failure(resource, %Warm{read: read}, reason) do
    Logger.warning("AshCache could not warm #{inspect(resource)}.#{read}: #{inspect(reason)}")
  end

  defp warm_one(resource, tenant, record, %Warm{read: read, args: args, actor: actor_mfa}) do
    actor = resolve_actor(actor_mfa)

    arguments =
      Map.new(args, fn {argument, attribute} -> {argument, Map.get(record, attribute)} end)

    resource
    |> Ash.Query.for_read(read, arguments, actor: actor, tenant: tenant)
    |> Ash.read(actor: actor, tenant: tenant)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp resolve_actor(nil), do: nil
  defp resolve_actor({module, function, args}), do: apply(module, function, args)

  # The change only registers an after_transaction hook, so it is safe under
  # atomic updates (Ash 3 defaults update actions to require_atomic? true).
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
