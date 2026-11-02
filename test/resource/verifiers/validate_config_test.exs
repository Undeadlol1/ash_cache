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

  test "accepts a reads list naming real read actions" do
    assert ValidateConfig.verify(PartiallyCachedWidget.spark_dsl_config()) == :ok
  end

  test "accepts a warm naming a cached read" do
    assert ValidateConfig.verify(WarmedWidget.spark_dsl_config()) == :ok
  end

  test "rejects a warm naming an uncached read" do
    state =
      Transformer.set_option(
        WarmedWidget.spark_dsl_config(),
        [:cache],
        :reads,
        [:read]
      )

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "warm :get_by_name"
  end

  test "rejects a reads entry that is not a read action" do
    state =
      Transformer.set_option(
        CachedWidget.spark_dsl_config(),
        [:cache],
        :reads,
        [:get_by_name, :no_such_read]
      )

    assert {:error, error} = ValidateConfig.verify(state)
    assert Exception.message(error) =~ "no_such_read"
    assert Exception.message(error) =~ "get_by_name"
  end
end
