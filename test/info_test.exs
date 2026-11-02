defmodule AshCache.InfoTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Widget

  test "a block naming only its reads reports every other default" do
    assert AshCache.Info.cache_ttl!(CachedWidget) == to_timeout(hour: 1)
    assert AshCache.Info.cache_store!(CachedWidget) == :ash_cache
    assert AshCache.Info.cache_reads!(CachedWidget) == [:read, :get_by_name, :paged]
    assert AshCache.Info.cache_cache_empty?(CachedWidget) == false
  end

  test "overrides are reported as declared" do
    assert AshCache.Info.cache_ttl!(PartiallyCachedWidget) == to_timeout(minute: 5)
    assert AshCache.Info.cache_store!(PartiallyCachedWidget) == :partial_store
    assert AshCache.Info.cache_reads!(PartiallyCachedWidget) == [:get_by_name]
    assert AshCache.Info.cache_cache_empty?(PartiallyCachedWidget) == true
  end

  test "cached?/1 tells extension users apart from plain resources" do
    assert AshCache.Info.cached?(CachedWidget)
    assert AshCache.Info.cached?(PartiallyCachedWidget)
    refute AshCache.Info.cached?(Widget)
  end
end
