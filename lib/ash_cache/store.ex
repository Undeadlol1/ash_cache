defmodule AshCache.Store do
  @moduledoc """
  Facade over the configured storage adapter.

  Adapter resolution, most specific first:

    1. `Process.put(:ash_cache_adapter, module)` — per-process override,
       used by tests that need to swap storage for a single test
    2. `config :ash_cache, adapter: module` — app-wide configuration
       (the test env configures `AshCache.Store.Adapters.ProcessLocal`
       so async tests are isolated by construction)
    3. `AshCache.Store.Adapters.Cachex` — production default
  """

  @default_adapter AshCache.Store.Adapters.Cachex

  @spec adapter() :: module()
  def adapter do
    Process.get(:ash_cache_adapter) ||
      Application.get_env(:ash_cache, :adapter, @default_adapter)
  end

  @spec get(atom(), term()) :: {:ok, term()} | {:error, term()}
  def get(store, key), do: adapter().get(store, key)

  @spec put(atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def put(store, key, value, opts \\ []), do: adapter().put(store, key, value, opts)

  @spec delete(atom(), term()) :: :ok | {:error, term()}
  def delete(store, key), do: adapter().delete(store, key)

  @spec clear(atom()) :: :ok | {:error, term()}
  def clear(store), do: adapter().clear(store)
end
