defmodule AshCache.Resource.Verifiers.ValidateCacheBlockTest do
  use ExUnit.Case, async: true

  alias AshCache.Resource.Verifiers.ValidateCacheBlock
  alias AshCache.Test.CachedWidget
  alias AshCache.Test.PartiallyCachedWidget

  # The verifier is unit-tested against a DSL state rather than by compiling
  # a bad module: Spark runs verifiers from `__verify_spark_dsl__/1` during
  # the module checker, so `assert_raise` around a `defmodule` never sees the
  # error.

  alias AshCache.Test.RefreshedWidget
  alias Spark.Dsl.Transformer

  defp cached_read(name), do: %AshCache.CachedRead{name: name, ttl: 1000}

  defp without_cached_reads(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:cache])
    |> Enum.filter(&match?(%AshCache.CachedRead{}, &1))
    |> Enum.reduce(dsl_state, fn read, dsl_state ->
      Transformer.remove_entity(dsl_state, [:cache], &(&1 == read))
    end)
  end

  test "accepts read entries naming real read actions" do
    assert ValidateCacheBlock.verify(PartiallyCachedWidget.spark_dsl_config()) == :ok
  end

  test "accepts a refresh naming a cached read" do
    assert ValidateCacheBlock.verify(RefreshedWidget.spark_dsl_config()) == :ok
  end

  test "rejects a refresh naming an uncached read" do
    dsl_state =
      RefreshedWidget.spark_dsl_config()
      |> without_cached_reads()
      |> Transformer.add_entity([:cache], cached_read(:read))

    assert {:error, error} = ValidateCacheBlock.verify(dsl_state)
    assert Exception.message(error) =~ "refresh :get_by_name"
  end

  test "rejects a cache block with no read entries" do
    dsl_state = without_cached_reads(CachedWidget.spark_dsl_config())

    assert {:error, error} = ValidateCacheBlock.verify(dsl_state)
    assert Exception.message(error) =~ "at least one `read`"
  end

  test "rejects a read that is not a read action" do
    dsl_state =
      Transformer.add_entity(
        CachedWidget.spark_dsl_config(),
        [:cache],
        cached_read(:no_such_read)
      )

    assert {:error, error} = ValidateCacheBlock.verify(dsl_state)
    assert Exception.message(error) =~ "no_such_read"
    assert Exception.message(error) =~ "get_by_name"
  end

  test "rejects a read that names a write action" do
    dsl_state =
      Transformer.add_entity(CachedWidget.spark_dsl_config(), [:cache], cached_read(:create))

    assert {:error, error} = ValidateCacheBlock.verify(dsl_state)
    assert Exception.message(error) =~ ":create"
  end

  test "rejects the same action declared by two read entries" do
    dsl_state =
      Transformer.add_entity(CachedWidget.spark_dsl_config(), [:cache], cached_read(:paged))

    assert {:error, error} = ValidateCacheBlock.verify(dsl_state)
    assert Exception.message(error) =~ "more than once"
    assert Exception.message(error) =~ ":paged"
  end
end
