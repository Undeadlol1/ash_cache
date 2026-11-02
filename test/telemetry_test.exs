defmodule AshCache.TelemetryTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.FailingGetAdapter
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Widget

  @events [
    [:ash_cache, :read, :hit],
    [:ash_cache, :read, :miss],
    [:ash_cache, :invalidate]
  ]

  setup do
    ref = make_ref()
    :telemetry.attach_many(ref, @events, &__MODULE__.forward_own_events/4, {self(), ref})
    on_exit(fn -> :telemetry.detach(ref) end)
    %{ref: ref}
  end

  def forward_own_events(event, measurements, metadata, {test_pid, ref}) do
    if self() == test_pid, do: send(test_pid, {event, ref, measurements, metadata})
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
      {[:ash_cache | _], _ref, _measurements, _metadata} -> flush_events()
    after
      0 -> :ok
    end
  end

  test "the first read is a miss and the identical second read is a hit", %{ref: ref} do
    create!(CachedWidget, "w")
    flush_events()

    get_by_name!(CachedWidget, "w")

    assert_received {[:ash_cache, :read, :miss], ^ref, measurements,
                     %{
                       resource: CachedWidget,
                       action: :get_by_name,
                       store: :ash_cache,
                       error: nil
                     }}

    assert measurements == %{}
    refute_received {[:ash_cache, :read, :hit], ^ref, _, _}

    get_by_name!(CachedWidget, "w")

    assert_received {[:ash_cache, :read, :hit], ^ref, %{},
                     %{resource: CachedWidget, action: :get_by_name, store: :ash_cache} = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :store]
    refute_received {[:ash_cache, :read, :miss], ^ref, _, _}
  end

  test "a different query on the same action is a miss", %{ref: ref} do
    get_by_name!(CachedWidget, "a")
    get_by_name!(CachedWidget, "a")
    flush_events()

    get_by_name!(CachedWidget, "b")

    assert_received {[:ash_cache, :read, :miss], ^ref, _, %{action: :get_by_name}}
    refute_received {[:ash_cache, :read, :hit], ^ref, _, _}
  end

  test "a write emits invalidate and the next read is a miss", %{ref: ref} do
    widget = create!(CachedWidget, "w")
    get_by_name!(CachedWidget, "w")
    flush_events()

    widget |> Ash.Changeset.for_update(:update, %{value: 2}) |> Ash.update!()

    assert_received {[:ash_cache, :invalidate], ^ref, %{},
                     %{resource: CachedWidget, store: :ash_cache} = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:resource, :store]

    get_by_name!(CachedWidget, "w")
    assert_received {[:ash_cache, :read, :miss], ^ref, _, _}
  end

  test "a create and a destroy each emit invalidate", %{ref: ref} do
    widget = create!(CachedWidget, "w")
    assert_received {[:ash_cache, :invalidate], ^ref, _, %{resource: CachedWidget}}

    Ash.destroy!(widget)
    assert_received {[:ash_cache, :invalidate], ^ref, _, %{resource: CachedWidget}}
  end

  test "AshCache.invalidate/1 emits invalidate", %{ref: ref} do
    :ok = AshCache.invalidate(PartiallyCachedWidget)

    assert_received {[:ash_cache, :invalidate], ^ref, %{},
                     %{resource: PartiallyCachedWidget, store: :partial_store}}
  end

  test "a failed write emits no invalidate", %{ref: ref} do
    widget = create!(CachedWidget, "w")
    flush_events()

    assert_raise Ash.Error.Invalid, fn ->
      widget |> Ash.Changeset.for_update(:update, %{name: nil}) |> Ash.update!()
    end

    refute_received {[:ash_cache, :invalidate], ^ref, _, _}
  end

  test "a bypassed read emits nothing", %{ref: ref} do
    flush_events()

    CachedWidget
    |> Ash.Query.new()
    |> Ash.Query.set_context(%{ash_cache: :bypass})
    |> Ash.read!()

    refute_received {[:ash_cache | _], ^ref, _, _}
  end

  test "a read action that is not cached emits nothing", %{ref: ref} do
    flush_events()

    Ash.read!(PartiallyCachedWidget)
    Ash.read!(Widget)

    refute_received {[:ash_cache, :read | _], ^ref, _, _}
  end

  test "metadata never carries actor or tenant", %{ref: ref} do
    get_by_name!(CachedWidget, "w")
    get_by_name!(CachedWidget, "w")
    AshCache.invalidate(CachedWidget)

    for _ <- 1..3 do
      assert_received {[:ash_cache | _], ^ref, _, metadata}
      refute Map.has_key?(metadata, :actor)
      refute Map.has_key?(metadata, :tenant)
    end
  end

  test "a store get error emits a miss carrying the error and still reads", %{ref: ref} do
    Process.put(:ash_cache_adapter, FailingGetAdapter)
    on_exit(fn -> Process.delete(:ash_cache_adapter) end)

    create!(CachedWidget, "w")
    flush_events()

    assert [%{name: "w"}] = get_by_name!(CachedWidget, "w")

    assert_received {[:ash_cache, :read, :miss], ^ref, %{},
                     %{
                       resource: CachedWidget,
                       action: :get_by_name,
                       store: :ash_cache,
                       error: :boom
                     }}
  end
end
