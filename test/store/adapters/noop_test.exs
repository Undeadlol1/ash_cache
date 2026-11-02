defmodule AshCache.Store.Adapters.NoopTest do
  use ExUnit.Case, async: true

  alias AshCache.Store.Adapters.Noop

  test "accepts writes and always misses" do
    assert :ok = Noop.put(:any, :key, "value", [])
    assert {:ok, nil} = Noop.get(:any, :key)
    assert :ok = Noop.delete(:any, :key)
    assert :ok = Noop.clear(:any)
  end
end
