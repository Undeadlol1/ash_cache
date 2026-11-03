defmodule AshCache.ResourceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "the extension wires its transformer and verifier" do
    assert AshCache.Resource.Transformers.AttachCacheHooks in AshCache.Resource.transformers()
    assert AshCache.Resource.Verifiers.ValidateCacheBlock in AshCache.Resource.verifiers()
  end

  test "the cache block carries the store, the default ttl and the resources that clear it" do
    [section] = AshCache.Resource.sections()

    assert section.name == :cache
    assert Keyword.keys(section.schema) == [:store, :ttl, :clear_when_changed]
    assert section.schema[:ttl][:default] == 300_000
    assert section.schema[:clear_when_changed][:default] == []
    assert section.schema[:store][:default] == :ash_cache
    assert Enum.map(section.entities, & &1.name) == [:read, :action, :calculation, :refresh]
  end

  test "a read entry has an optional ttl and defaults the rest" do
    [section] = AshCache.Resource.sections()
    read = Enum.find(section.entities, &(&1.name == :read))

    assert read.target == AshCache.CachedRead
    assert read.args == [:name]
    refute read.schema[:ttl][:required]
    refute Keyword.has_key?(read.schema[:ttl], :default)
    assert read.schema[:cache_empty?][:default] == false
    assert read.schema[:store_options][:default] == []
  end

  test "a read without a ttl compiles" do
    compile_cached_resource("read :read")
  end

  test "a zero or negative block ttl does not compile" do
    for ttl <- [0, -5] do
      assert_raise Spark.Error.DslError, ~r/ttl/, fn ->
        compile_cached_resource("ttl #{ttl}\n        read :read")
      end
    end
  end

  test "an :infinity ttl compiles on the block and on a read" do
    compile_cached_resource("ttl :infinity\n        read :read")
    compile_cached_resource("read :read, ttl: :infinity")
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

  test "the old block-level reads option does not compile" do
    assert_raise CompileError, fn ->
      compile_cached_resource("reads [:read]")
    end
  end

  defp compile_cached_resource(cache_body) do
    name = "AshCache.Test.Compiled#{System.unique_integer([:positive])}"

    # Compiling at test time prints the expected compile errors and a
    # protocol-consolidation warning to stderr; keep them out of the run.
    capture_io(:stderr, fn -> Code.compile_string(source(name, cache_body)) end)
  end

  defp source(name, cache_body) do
    """
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
    """
  end
end
