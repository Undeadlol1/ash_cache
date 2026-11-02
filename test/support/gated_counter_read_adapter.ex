defmodule AshCache.Test.GatedCounterReadAdapter do
  @moduledoc false

  @behaviour AshCache.Store.Adapter

  alias AshCache.Store.Adapters.Cachex, as: CachexAdapter

  @impl true
  def get(store, {:ash_cache_generation, _resource} = key) do
    result = CachexAdapter.get(store, key)

    case Process.get(:gate_owner) do
      nil ->
        result

      owner ->
        send(owner, {:read_counter, self(), result})

        receive do
          :proceed -> result
        end
    end
  end

  def get(store, key), do: CachexAdapter.get(store, key)

  @impl true
  defdelegate put(store, key, value, opts), to: CachexAdapter

  @impl true
  defdelegate del(store, key), to: CachexAdapter

  @impl true
  defdelegate clear(store), to: CachexAdapter
end
