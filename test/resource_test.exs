defmodule AshCache.ResourceTest do
  use ExUnit.Case, async: true

  test "the extension wires its transformer and verifier" do
    assert AshCache.Resource.Transformers.AttachCacheHooks in AshCache.Resource.transformers()
    assert AshCache.Resource.Verifiers.ValidateConfig in AshCache.Resource.verifiers()
  end

  test "the section carries the documented defaults" do
    [section] = AshCache.Resource.sections()

    assert section.name == :cache
    assert section.schema[:ttl][:default] == to_timeout(hour: 1)
    assert section.schema[:store][:default] == :ash_cache
    assert section.schema[:reads][:default] == :all
    assert section.schema[:cache_empty?][:default] == false
    assert section.schema[:adapter_options][:default] == []
  end
end
