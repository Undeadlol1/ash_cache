defmodule AshCacheTest do
  use ExUnit.Case, async: true

  alias AshCache.Generation
  alias AshCache.Store
  alias AshCache.Test.CachedWidget

  test "invalidating a resource bumps its generation in its declared store" do
    assert Generation.current(:ash_cache, CachedWidget) == 0

    assert :ok = AshCache.invalidate(CachedWidget)

    refute Generation.current(:ash_cache, CachedWidget) == 0
  end

  test "clearing a store empties it" do
    :ok = Store.put(:ash_cache, :key, "value")

    assert :ok = AshCache.clear_store(:ash_cache)

    assert {:ok, nil} = Store.get(:ash_cache, :key)
  end
end
