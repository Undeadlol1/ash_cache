defmodule AshCache.Resource.Verifiers.ValidateConfigTest do
  use ExUnit.Case, async: true

  alias AshCache.Resource.Verifiers.ValidateConfig
  alias AshCache.Test.CachedWidget
  alias AshCache.Test.PartiallyCachedWidget

  # The verifier is unit-tested against a DSL state rather than by compiling
  # a bad module: Spark runs verifiers from `__verify_spark_dsl__/1` during
  # the module checker, so `assert_raise` around a `defmodule` never sees the
  # error.

  alias AshCache.Test.WarmedWidget
  alias Spark.Dsl.Transformer

  defp read_entity(name), do: %AshCache.CachedRead{name: name, ttl: 1000}

  defp without_read_entities(state) do
    state
    |> Transformer.get_entities([:cache])
    |> Enum.filter(&match?(%AshCache.CachedRead{}, &1))
    |> Enum.reduce(state, fn read, state ->
      Transformer.remove_entity(state, [:cache], &(&1 == read))
    end)
  end

  test "accepts read entities naming real read actions" do
    assert ValidateConfig.verify(PartiallyCachedWidget.spark_dsl_config()) == :ok
  end

  test "accepts a warm naming a cached read" do
    assert ValidateConfig.verify(WarmedWidget.spark_dsl_config()) == :ok
  end

  test "rejects a warm naming an uncached read" do
    state =
      WarmedWidget.spark_dsl_config()
      |> without_read_entities()
      |> Transformer.add_entity([:cache], read_entity(:read))

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "warm :get_by_name"
  end

  test "rejects a cache block with no read entities" do
    state = without_read_entities(CachedWidget.spark_dsl_config())

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "at least one `read`"
  end

  test "rejects a read that is not a read action" do
    state =
      Transformer.add_entity(
        CachedWidget.spark_dsl_config(),
        [:cache],
        read_entity(:no_such_read)
      )

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "no_such_read"
    assert Exception.message(error) =~ "get_by_name"
  end

  test "rejects a read that names a write action" do
    state =
      Transformer.add_entity(CachedWidget.spark_dsl_config(), [:cache], read_entity(:create))

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ ":create"
  end

  test "rejects the same action declared by two read entities" do
    state =
      Transformer.add_entity(CachedWidget.spark_dsl_config(), [:cache], read_entity(:paged))

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "more than once"
    assert Exception.message(error) =~ ":paged"
  end
end
