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
    assert section.schema[:reads][:required] == true
    refute Keyword.has_key?(section.schema[:reads], :default)
    assert section.schema[:cache_empty?][:default] == false
    assert section.schema[:adapter_options][:default] == []
  end

  # Caching is opt-in per read: a cache block that does not say which reads
  # to cache is a mistake, not a request to cache everything.
  test "a cache block without reads does not compile" do
    assert_raise Spark.Error.DslError, ~r/reads/, fn ->
      compile_cached_resource("")
    end
  end

  test "reads must be a list of action names, not :all" do
    assert_raise Spark.Error.DslError, ~r/reads/, fn ->
      compile_cached_resource("reads :all")
    end
  end

  defp compile_cached_resource(cache_body) do
    name = "AshCache.Test.Compiled#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshCache.Resource],
        validate_domain_inclusion?: false

      cache do
        #{cache_body}
      end

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end
    end
    """)
  end
end
