defmodule AshCache.RefreshTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshCache.Changes.InvalidateCache
  alias AshCache.Test.RefreshedWidget

  test "a refresh declares its options and which are required" do
    schema = AshCache.Refresh.schema()

    assert schema[:read][:required] == true
    assert schema[:arguments][:default] == []
    assert schema[:actor][:default] == nil
  end

  test "a declared refresh is readable through the info module" do
    assert [refresh] =
             Enum.filter(AshCache.Info.cache(RefreshedWidget), &match?(%AshCache.Refresh{}, &1))

    assert refresh.read == :get_by_name
    assert refresh.arguments == [name: :name]
    assert refresh.actor == nil
  end

  test "declared refreshes are handed to the write actions' invalidating change" do
    assert [%AshCache.Refresh{read: :get_by_name}] =
             invalidating_change_options(RefreshedWidget)[:refresh]
  end

  test "a resource declaring no refresh hands the invalidating change an empty refresh list, so the extra read is paid only where one is declared" do
    assert invalidating_change_options(AshCache.Test.Widget)[:refresh] in [nil, []]
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
