defmodule AshCache.Store.Adapters.CachexTest do
  use ExUnit.Case, async: true
  use AshCache.Test.StoreContract, adapter: AshCache.Store.Adapters.Cachex

  setup do
    store = :"cachex_store_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})
    {:ok, store: store}
  end

  test "get, put, del and clear operate on the real Cachex table", %{store: store} do
    assert {:ok, nil} = @adapter.get(store, :missing)

    :ok = @adapter.put(store, :kept, "value", [])
    assert {:ok, 1} = Cachex.size(store)

    :ok = @adapter.del(store, :kept)
    :ok = @adapter.clear(store)
    assert {:ok, 0} = Cachex.size(store)
  end

  test "an :infinity ttl stores an entry that never expires", %{store: store} do
    :ok = @adapter.put(store, :forever, "value", ttl: :infinity)

    assert {:ok, nil} = Cachex.ttl(store, :forever)
    assert {:ok, "value"} = @adapter.get(store, :forever)
  end
end
