defmodule AshCache.NebulexStoreTest do
  @moduledoc """
  Real reads and writes cached in a Nebulex cache, through
  `AshCache.Store.Adapters.Nebulex`.
  """

  # One shared cache module, so tests must not run alongside each other.
  use ExUnit.Case, async: false

  alias AshCache.Store
  alias AshCache.Test.Events
  alias AshCache.Test.NebulexCache
  alias AshCache.Test.NebulexWidget
  alias AshCache.Test.StoreContract

  setup do
    start_supervised!(NebulexCache)
    previous = Process.get(:ash_cache_adapter)
    Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Nebulex)
    on_exit(fn -> StoreContract.restore_adapter(previous) end)
    AshCache.Testing.capture_events()
  end

  defp create!(value) do
    NebulexWidget
    |> Ash.Changeset.for_create(:create, %{name: "w", value: value})
    |> Ash.create!()
  end

  defp update!(widget, value) do
    widget
    |> Ash.Changeset.for_update(:update, %{value: value})
    |> Ash.update!()
  end

  defp read_value(action \\ :get_by_name) do
    query =
      if action == :get_by_name,
        do: Ash.Query.for_read(NebulexWidget, :get_by_name, %{name: "w"}),
        else: Ash.Query.for_read(NebulexWidget, action)

    [%{value: value}] = Ash.read!(query)
    value
  end

  test "a miss, then a hit" do
    create!(1)
    Events.drain()

    assert read_value() == 1
    assert read_value() == 1
    assert Events.drain() == [:miss, :hit]
  end

  test "a write clears cached reads" do
    widget = create!(1)
    assert read_value() == 1

    update!(widget, 2)
    Events.drain()
    assert read_value() == 2
    assert Events.drain() == [:miss]
  end

  test "AshCache.invalidate/1 clears cached reads" do
    create!(1)
    assert read_value() == 1

    :ok = AshCache.invalidate(NebulexWidget)
    Events.drain()
    assert read_value() == 1
    assert Events.drain() == [:miss]
  end

  test "an entry past its ttl is read again" do
    create!(1)
    assert read_value(:read) == 1
    Process.sleep(5)
    Events.drain()

    assert read_value(:read) == 1
    assert Events.drain() == [:miss]
  end

  test "a counter the cache loses after writes never brings back old entries" do
    widget = create!(1)
    assert read_value() == 1

    update!(widget, 2)
    assert read_value() == 2
    :ok = Store.del(NebulexCache, {:ash_cache_generation, NebulexWidget})

    update!(widget, 3)
    :ok = Store.del(NebulexCache, {:ash_cache_generation, NebulexWidget})
    assert read_value() == 3
  end

  test "a cache emptied or restarted never brings back old entries" do
    widget = create!(1)
    assert read_value() == 1
    update!(widget, 2)

    :ok = AshCache.clear_store(NebulexCache)
    assert read_value() == 2

    stop_supervised!(NebulexCache)
    assert read_value() == 2
    start_supervised!(NebulexCache)
    assert read_value() == 2
  end
end
