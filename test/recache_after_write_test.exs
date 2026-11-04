defmodule AshCache.RecacheAfterWriteTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshCache.Changes.InvalidateCache
  alias AshCache.Test.RecachedWidget

  test "a recache declares its options and which are required" do
    schema = AshCache.RecacheAfterWrite.schema()

    assert schema[:read][:required] == true
    assert schema[:arguments][:default] == []
    assert schema[:actor][:default] == nil
  end

  test "a declared recache is readable through the info module" do
    assert [recache] =
             Enum.filter(
               AshCache.Info.cache(RecachedWidget),
               &match?(%AshCache.RecacheAfterWrite{}, &1)
             )

    assert recache.read == :get_by_name
    assert recache.arguments == []
    assert recache.actor == nil
  end

  test "declared recaches are handed to the write actions' invalidating change" do
    assert [%AshCache.RecacheAfterWrite{read: :get_by_name}] =
             invalidating_change_options(RecachedWidget)[:recache_after_write]
  end

  test "a resource declaring no recache hands the invalidating change an empty recache list, so the extra read is paid only where one is declared" do
    assert invalidating_change_options(AshCache.Test.Widget)[:recache_after_write] in [nil, []]
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
