defmodule AshCache.StoreTest do
  use ExUnit.Case, async: true

  alias AshCache.Store
  alias AshCache.Store.Adapters.Noop
  alias AshCache.Store.Adapters.ProcessLocal

  describe "adapter resolution" do
    test "a process override wins" do
      previous_adapter = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, Noop)

      assert Store.adapter() == Noop

      if previous_adapter do
        Process.put(:ash_cache_adapter, previous_adapter)
      else
        Process.delete(:ash_cache_adapter)
      end
    end

    test "the app-wide adapter comes from the app config" do
      assert Application.get_env(:ash_cache, :adapter) == ProcessLocal

      assert Store.adapter() == ProcessLocal
    end
  end

  describe "calling through to the adapter" do
    test "get, put, delete and clear reach the configured adapter" do
      store = :"facade_store_#{System.unique_integer([:positive])}"

      assert {:ok, nil} = Store.get(store, :key)
      assert :ok = Store.put(store, :key, "value", ttl: to_timeout(hour: 1))
      assert {:ok, "value"} = Store.get(store, :key)
      assert :ok = Store.delete(store, :key)
      assert {:ok, nil} = Store.get(store, :key)

      assert :ok = Store.put(store, :other, "value")
      assert :ok = Store.clear(store)
      assert {:ok, nil} = Store.get(store, :other)
    end
  end
end
