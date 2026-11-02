defmodule AshCache.TelemetryTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.FailingGetAdapter
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Widget

  setup do
    AshCache.Testing.capture_events()
  end

  defp create!(resource, name) do
    resource
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  defp get_by_name!(resource, name) do
    resource
    |> Ash.Query.for_read(:get_by_name, %{name: name})
    |> Ash.read!()
  end

  defp flush_events do
    receive do
      {:ash_cache, _kind, _metadata} -> flush_events()
    after
      0 -> :ok
    end
  end

  test "the first read is a miss and the identical second read is a hit" do
    create!(CachedWidget, "w")
    flush_events()

    get_by_name!(CachedWidget, "w")

    assert_received {:ash_cache, :miss,
                     %{
                       resource: CachedWidget,
                       action: :get_by_name,
                       store: :ash_cache,
                       error: nil
                     }}

    refute_received {:ash_cache, :hit, _}

    get_by_name!(CachedWidget, "w")

    assert_received {:ash_cache, :hit,
                     %{resource: CachedWidget, action: :get_by_name, store: :ash_cache} = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :store]
    refute_received {:ash_cache, :miss, _}
  end

  test "a different query on the same action is a miss" do
    get_by_name!(CachedWidget, "a")
    get_by_name!(CachedWidget, "a")
    flush_events()

    get_by_name!(CachedWidget, "b")

    assert_received {:ash_cache, :miss, %{action: :get_by_name}}
    refute_received {:ash_cache, :hit, _}
  end

  test "a write emits invalidate and the next read is a miss" do
    widget = create!(CachedWidget, "w")
    get_by_name!(CachedWidget, "w")
    flush_events()

    widget |> Ash.Changeset.for_update(:update, %{quantity: 2}) |> Ash.update!()

    assert_received {:ash_cache, :invalidate,
                     %{resource: CachedWidget, store: :ash_cache} = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:resource, :store]

    get_by_name!(CachedWidget, "w")
    assert_received {:ash_cache, :miss, _}
  end

  test "a create and a destroy each emit invalidate" do
    widget = create!(CachedWidget, "w")
    assert_received {:ash_cache, :invalidate, %{resource: CachedWidget}}

    Ash.destroy!(widget)
    assert_received {:ash_cache, :invalidate, %{resource: CachedWidget}}
  end

  test "invalidating by hand emits invalidate" do
    :ok = AshCache.invalidate(PartiallyCachedWidget)

    assert_received {:ash_cache, :invalidate,
                     %{resource: PartiallyCachedWidget, store: :partial_store}}
  end

  test "a failed write emits no invalidate" do
    widget = create!(CachedWidget, "w")
    flush_events()

    assert_raise Ash.Error.Invalid, fn ->
      widget |> Ash.Changeset.for_update(:update, %{name: nil}) |> Ash.update!()
    end

    refute_received {:ash_cache, :invalidate, _}
  end

  test "a bypassed read emits nothing" do
    flush_events()

    CachedWidget
    |> Ash.Query.new()
    |> Ash.Query.set_context(%{ash_cache: :bypass})
    |> Ash.read!()

    refute_received {:ash_cache, _, _}
  end

  test "a read action that is not cached emits nothing" do
    flush_events()

    Ash.read!(PartiallyCachedWidget)
    Ash.read!(Widget)

    refute_received {:ash_cache, :hit, _}
    refute_received {:ash_cache, :miss, _}
  end

  test "metadata never carries actor or tenant" do
    get_by_name!(CachedWidget, "w")
    get_by_name!(CachedWidget, "w")
    AshCache.invalidate(CachedWidget)

    for _ <- 1..3 do
      assert_received {:ash_cache, _, metadata}
      refute Map.has_key?(metadata, :actor)
      refute Map.has_key?(metadata, :tenant)
    end
  end

  test "a store that fails to answer emits a miss carrying the error and still reads" do
    Process.put(:ash_cache_adapter, FailingGetAdapter)
    on_exit(fn -> Process.delete(:ash_cache_adapter) end)

    create!(CachedWidget, "w")
    flush_events()

    assert [%{name: "w"}] = get_by_name!(CachedWidget, "w")

    assert_received {:ash_cache, :miss,
                     %{
                       resource: CachedWidget,
                       action: :get_by_name,
                       store: :ash_cache,
                       error: :boom
                     }}
  end
end
