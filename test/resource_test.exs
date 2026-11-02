defmodule AshCache.ResourceTest do
  use ExUnit.Case, async: true

  test "the extension wires its transformer and verifier" do
    assert AshCache.Resource.Transformers.AttachCacheHooks in AshCache.Resource.transformers()
    assert AshCache.Resource.Verifiers.ValidateConfig in AshCache.Resource.verifiers()
  end

  test "the section only carries the store" do
    [section] = AshCache.Resource.sections()

    assert section.name == :cache
    assert Keyword.keys(section.schema) == [:store]
    assert section.schema[:store][:default] == :ash_cache
    assert Enum.map(section.entities, & &1.name) == [:read, :action, :warm]
  end

  test "the read entity requires a ttl and defaults the rest" do
    [section] = AshCache.Resource.sections()
    read = Enum.find(section.entities, &(&1.name == :read))

    assert read.target == AshCache.CachedRead
    assert read.args == [:name]
    assert read.schema[:ttl][:required] == true
    refute Keyword.has_key?(read.schema[:ttl], :default)
    assert read.schema[:cache_empty?][:default] == false
    assert read.schema[:adapter_options][:default] == []
  end

  test "a read without a ttl does not compile" do
    assert_raise Spark.Error.DslError, ~r/ttl/, fn ->
      compile_cached_resource("read :read")
    end
  end

  test "a zero ttl does not compile" do
    assert_raise Spark.Error.DslError, ~r/ttl/, fn ->
      compile_cached_resource("read :read, ttl: 0")
    end
  end

  test "a negative ttl does not compile" do
    assert_raise Spark.Error.DslError, ~r/ttl/, fn ->
      compile_cached_resource("read :read, ttl: -5")
    end
  end

  test "an :infinity ttl does not compile" do
    assert_raise Spark.Error.DslError, ~r/ttl/, fn ->
      compile_cached_resource("read :read, ttl: :infinity")
    end
  end

  test "the old section-level reads option does not compile" do
    assert_raise CompileError, fn ->
      compile_cached_resource("reads [:read]")
    end
  end

  test "the old section-level ttl option does not compile" do
    assert_raise CompileError, fn ->
      compile_cached_resource("read :read, ttl: 1000\n        ttl 1000")
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
