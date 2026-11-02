defmodule AshCache.InfoTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Widget

  test "a block reports its store and one entity per cached read" do
    assert AshCache.Info.cache_store!(CachedWidget) == :ash_cache

    reads = Enum.filter(AshCache.Info.cache(CachedWidget), &match?(%AshCache.CachedRead{}, &1))

    assert Enum.map(reads, & &1.name) == [:read, :get_by_name, :paged]
    assert Enum.all?(reads, &(&1.ttl == to_timeout(hour: 1)))
    assert Enum.all?(reads, &(&1.cache_empty? == false and &1.adapter_options == []))
  end

  test "overrides are reported as declared" do
    assert AshCache.Info.cache_store!(PartiallyCachedWidget) == :partial_store

    assert [%AshCache.CachedRead{name: :get_by_name, ttl: ttl, cache_empty?: true}] =
             AshCache.Info.cache(PartiallyCachedWidget)

    assert ttl == to_timeout(minute: 5)
  end

  test "cached?/1 tells extension users apart from plain resources" do
    assert AshCache.Info.cached?(CachedWidget)
    assert AshCache.Info.cached?(PartiallyCachedWidget)
    refute AshCache.Info.cached?(Widget)
  end
end
