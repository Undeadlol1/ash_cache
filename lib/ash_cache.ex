defmodule AshCache do
  @moduledoc """
  Declarative read-through caching for Ash resources. See `AshCache.Resource`
  for the DSL and `README.md` in this directory for the design.

  These helpers are the runtime escape hatch for operational situations
  (a support task, a migration) that need to reach past the declarative
  layer.

  ## Telemetry

  Three `:telemetry` events let you assert cache behaviour in tests and
  measure hit rates in production. All have empty measurements. Reads that
  are bypassed, or not cached, emit nothing. Actor and tenant are never in
  the metadata.

    * `[:ash_cache, :read, :hit]` - a cached read was answered without the
      data layer: from the store, or with the records of an identical read
      running at the same time (see `AshCache.Coalesce`). Metadata:
      `:resource`, `:action`, `:store`.
    * `[:ash_cache, :read, :miss]` - a cached read was not in the store and
      went to the data layer. Metadata: `:resource`, `:action`, `:store`,
      and `:error`, which is `nil` normally or the reason when the store
      failed to answer (the read still goes through).
    * `[:ash_cache, :invalidate]` - a resource's cache was invalidated, by
      a successful create, update or destroy or by `invalidate/1`.
      Metadata: `:resource`, `:store`.
  """

  alias AshCache.Generation
  alias AshCache.Info
  alias AshCache.Store

  @doc """
  Invalidates every cached read of a resource, exactly like a successful
  write does.
  """
  @spec invalidate(Ash.Resource.t()) :: :ok | {:error, term()}
  def invalidate(resource) do
    Generation.bump(Info.cache_store!(resource), resource)
  end

  @doc "Clears a whole store, including other resources' entries."
  @spec clear_store(atom()) :: :ok | {:error, term()}
  def clear_store(store), do: Store.clear(store)
end
