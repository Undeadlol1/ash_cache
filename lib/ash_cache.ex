defmodule AshCache do
  @moduledoc """
  Declarative read-through caching for Ash resources. See `AshCache.Resource`
  for the DSL and `README.md` in this directory for the design.

  These helpers are the runtime escape hatch for operational situations
  (a support task, a migration) that need to reach past the declarative
  layer.
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
