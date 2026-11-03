defmodule AshCacheTest do
  use ExUnit.Case, async: true

  alias AshCache.CacheVersion
  alias AshCache.Store
  alias AshCache.Test.CachedWidget

  test "invalidating a resource bumps its cache version in its declared store" do
    before = CacheVersion.current(:ash_cache, CachedWidget)

    assert :ok = AshCache.invalidate(CachedWidget)

    refute CacheVersion.current(:ash_cache, CachedWidget) == before
  end

  test "clearing a store empties it" do
    :ok = Store.put(:ash_cache, :key, "value")

    assert :ok = AshCache.clear_store(:ash_cache)

    assert {:ok, nil} = Store.get(:ash_cache, :key)
  end
end
