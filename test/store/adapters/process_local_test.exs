defmodule AshCache.Store.Adapters.ProcessLocalTest do
  use ExUnit.Case, async: true
  use AshCache.Test.StoreContract, adapter: AshCache.Store.Adapters.ProcessLocal

  setup do
    {:ok, store: :"process_local_store_#{System.unique_integer([:positive])}"}
  end

  test "entries are invisible to other processes", %{store: store} do
    :ok = @adapter.put(store, :key, "value", [])

    task = Task.async(fn -> @adapter.get(store, :key) end)

    assert {:ok, nil} = Task.await(task)
  end

  test "the store is bounded: overflowing entries resets it instead of leaking", %{store: store} do
    limit = AshCache.Store.Adapters.ProcessLocal.max_entries_per_store()

    for n <- 1..(limit + 1) do
      :ok = @adapter.put(store, {:key, n}, n, [])
    end

    tracked = Enum.count(Process.get_keys(), &match?({:ash_cache_entry, ^store, _}, &1))

    assert tracked <= limit
    newest = limit + 1
    assert {:ok, ^newest} = @adapter.get(store, {:key, newest})
  end

  test "del and clear also drop the process-dictionary key tracking", %{store: store} do
    :ok = @adapter.put(store, :tracked, 1, [])
    :ok = @adapter.del(store, :tracked)
    :ok = @adapter.clear(store)

    assert Enum.filter(Process.get_keys(), &match?({:ash_cache_keys, ^store}, &1)) == []
  end
end
