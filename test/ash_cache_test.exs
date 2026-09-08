defmodule AshCacheTest do
  use ExUnit.Case, async: true

  alias AshCache.Generation
  alias AshCache.Store
  alias AshCache.Test.CachedWidget

  test "invalidate/1 bumps the resource's generation in its declared store" do
    assert Generation.current(:ash_cache, CachedWidget) == 0

    assert :ok = AshCache.invalidate(CachedWidget)

    assert Generation.current(:ash_cache, CachedWidget) == 1
  end

  test "clear_store/1 empties the store" do
    :ok = Store.put(:ash_cache, :key, "value")

    assert :ok = AshCache.clear_store(:ash_cache)

    assert {:ok, nil} = Store.get(:ash_cache, :key)
  end
end
