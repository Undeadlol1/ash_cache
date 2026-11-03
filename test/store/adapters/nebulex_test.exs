defmodule AshCache.Store.Adapters.NebulexTest do
  # One shared cache module, so tests must not run alongside each other.
  use ExUnit.Case, async: false
  use AshCache.Test.StoreContract, adapter: AshCache.Store.Adapters.Nebulex

  alias AshCache.Test.NebulexCache

  setup do
    start_supervised!(NebulexCache)
    {:ok, store: NebulexCache}
  end

  test "writes land in the Nebulex cache itself", %{store: store} do
    :ok = @adapter.put(store, :kept, "value", ttl: to_timeout(hour: 1), never_evict: true)
    assert {:ok, "value"} = NebulexCache.get(:kept)

    :ok = @adapter.delete(store, :kept)
    assert {:ok, false} = NebulexCache.has_key?(:kept)
  end

  test "a cache that is not running is an error, not a miss", %{store: store} do
    stop_supervised!(NebulexCache)

    assert {:error, _} = @adapter.get(store, :key)
    assert {:error, _} = @adapter.put(store, :key, "value", [])
  end
end
