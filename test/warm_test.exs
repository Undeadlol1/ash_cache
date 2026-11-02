defmodule AshCache.WarmTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshCache.Changes.InvalidateCache
  alias AshCache.Test.WarmedWidget

  test "a warm declares its options and which are required" do
    schema = AshCache.Warm.schema()

    assert schema[:read][:required] == true
    assert schema[:args][:default] == []
    assert schema[:actor][:default] == nil
  end

  test "a declared warm is readable through the info module" do
    assert [warm] = Enum.filter(AshCache.Info.cache(WarmedWidget), &match?(%AshCache.Warm{}, &1))

    assert warm.read == :get_by_name
    assert warm.args == [name: :name]
    assert warm.actor == nil
  end

  test "declared warms are handed to the write actions' invalidating change" do
    assert [%AshCache.Warm{read: :get_by_name}] = invalidating_change_options(WarmedWidget)[:warm]
  end

  test "a resource declaring no warm hands the invalidating change an empty warm list, so the extra read is paid only where one is declared" do
    assert invalidating_change_options(AshCache.Test.Widget)[:warm] in [nil, []]
  end

  defp invalidating_change_options(resource) do
    resource
    |> Info.action(:create)
    |> Map.fetch!(:changes)
    |> Enum.find_value(fn
      %{change: {InvalidateCache, opts}} -> opts
      _other -> nil
    end)
  end
end
