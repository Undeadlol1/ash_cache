defmodule AshCache.IntegrationTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Domain
  alias AshCache.Test.Events
  alias AshCache.Test.GuardedWidget
  alias AshCache.Test.OwnedWidget
  alias AshCache.Test.TwoTtlWidget

  setup do
    AshCache.Testing.capture_events()
  end

  defp create!(name, value \\ 0) do
    CachedWidget
    |> Ash.Changeset.for_create(:create, %{name: name, value: value})
    |> Ash.create!()
  end

  defp get_by_name!(name) do
    CachedWidget
    |> Ash.Query.for_read(:get_by_name, %{name: name})
    |> Ash.read!()
  end

  # After this, a data-layer read returns nothing, so any record still
  # coming back can only have come from the cache.
  defp wipe_data_layer! do
    {:ok, _table} = Ash.DataLayer.Ets.stop(CachedWidget)
    # stop/1 deletes the table but leaves this reference, which later
    # data-layer calls crash on instead of starting fresh.
    Process.delete({:ash_ets_table, CachedWidget, nil})
  end

  test "a cache hit skips the data layer entirely" do
    create!("cached", 42)

    assert [%{value: 42}] = get_by_name!("cached")

    wipe_data_layer!()

    assert [%{value: 42}] = get_by_name!("cached")
  end

  test "a bypassed read goes to the data layer every time" do
    create!("fresh")

    assert [%{name: "fresh"}] = Ash.read!(CachedWidget)
    assert [%{name: "fresh"}] = Ash.read!(CachedWidget)
    assert Events.drain() == [:invalidate, :miss, :hit]

    wipe_data_layer!()

    assert [%{name: "fresh"}] = Ash.read!(CachedWidget)
    assert Events.drain() == [:hit]

    bypassed = Ash.Query.set_context(Ash.Query.new(CachedWidget), %{ash_cache: :bypass})
    assert [] = Ash.read!(bypassed)

    create!("replacement")
    Events.drain()

    assert [%{name: "replacement"}] = Ash.read!(bypassed)
    assert [%{name: "replacement"}] = Ash.read!(bypassed)
    assert Events.drain() == []
  end

  test "an update invalidates cached reads" do
    widget = create!("mutable", 1)

    assert [%{value: 1}] = get_by_name!("mutable")
    assert [%{value: 1}] = get_by_name!("mutable")
    assert Events.drain() == [:invalidate, :miss, :hit]

    widget
    |> Ash.Changeset.for_update(:update, %{value: 2})
    |> Ash.update!()

    assert Events.drain() == [:invalidate]

    assert [%{value: 2}] = get_by_name!("mutable")
    assert Events.drain() == [:miss]
  end

  test "a destroy invalidates cached reads" do
    widget = create!("doomed")

    assert [_widget] = get_by_name!("doomed")
    assert [_widget] = get_by_name!("doomed")
    assert Events.drain() == [:invalidate, :miss, :hit]

    Ash.destroy!(widget)
    assert Events.drain() == [:invalidate]

    assert [] = get_by_name!("doomed")
    assert Events.drain() == [:miss]
  end

  test "a failed write neither invalidates nor poisons the cache" do
    widget = create!("stable", 7)

    assert [%{value: 7}] = get_by_name!("stable")

    assert_raise Ash.Error.Invalid, fn ->
      widget
      |> Ash.Changeset.for_update(:update, %{name: nil})
      |> Ash.update!()
    end

    wipe_data_layer!()

    assert [%{value: 7}] = get_by_name!("stable")
  end

  test "a get_by code interface does not collide with the unfiltered read" do
    first = create!("first")
    second = create!("second")
    Events.drain()

    assert length(Ash.read!(CachedWidget)) == 2
    assert Domain.get_cached_widget!(first.id).name == "first"
    assert Domain.get_cached_widget!(second.id).name == "second"
    assert Events.drain() == [:miss, :miss, :miss]

    assert length(Ash.read!(CachedWidget)) == 2
    assert Domain.get_cached_widget!(first.id).name == "first"
    assert Events.drain() == [:hit, :hit]
  end

  test "pages of one query do not collide in the cache" do
    for name <- ["a", "b", "c", "d"], do: create!(name)
    Events.drain()

    read_page = fn offset ->
      CachedWidget
      |> Ash.Query.for_read(:paged, %{})
      |> Ash.read!(page: [limit: 2, offset: offset])
    end

    first_page = read_page.(0)
    second_page = read_page.(2)
    assert Events.drain() == [:miss, :miss]

    first_names = Enum.map(first_page.results, & &1.name)
    second_names = Enum.map(second_page.results, & &1.name)

    assert length(first_names) == 2
    assert length(second_names) == 2
    assert MapSet.disjoint?(MapSet.new(first_names), MapSet.new(second_names))

    assert Enum.map(read_page.(2).results, & &1.name) == second_names
    assert Enum.map(read_page.(0).results, & &1.name) == first_names
    assert Events.drain() == [:hit, :hit]
  end

  defp read_without_actor do
    {:ok, rows} = Ash.read(GuardedWidget, actor: nil)
    rows
  end

  test "an authorized read's cached rows never leak to an actorless read" do
    actor = %{id: "someone"}

    GuardedWidget
    |> Ash.Changeset.for_create(:create, %{name: "secret"})
    |> Ash.create!(actor: actor)

    Events.drain()

    assert [%{name: "secret"}] = Ash.read!(GuardedWidget, actor: actor)
    assert [%{name: "secret"}] = Ash.read!(GuardedWidget, actor: actor)
    assert Events.drain() == [:miss, :hit]

    assert read_without_actor() == []
    assert :hit not in Events.drain()
  end

  test "an authorize?: false read's cached rows never leak to an actorless read" do
    GuardedWidget
    |> Ash.Changeset.for_create(:create, %{name: "secret"}, authorize?: false)
    |> Ash.create!(authorize?: false)

    Events.drain()

    assert [%{name: "secret"}] = Ash.read!(GuardedWidget, authorize?: false)
    assert [%{name: "secret"}] = Ash.read!(GuardedWidget, authorize?: false)
    assert Events.drain() == [:miss, :hit]

    assert read_without_actor() == []
    assert :hit not in Events.drain()
  end

  test "an authorize?: false read's rows never answer the same actor's authorized read" do
    actor = %{id: "owner"}

    for name <- ["owner", "stranger"] do
      OwnedWidget
      |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    Events.drain()

    assert length(Ash.read!(OwnedWidget, actor: actor, authorize?: false)) == 2
    assert length(Ash.read!(OwnedWidget, actor: actor, authorize?: false)) == 2
    assert Events.drain() == [:miss, :hit]

    assert [%{name: "owner"}] = Ash.read!(OwnedWidget, actor: actor)
    assert Events.drain() == [:miss]

    assert [%{name: "owner"}] = Ash.read!(OwnedWidget, actor: actor)
    assert Events.drain() == [:hit]
  end

  test "a year of write-then-read cycles stays bounded and always reads fresh" do
    widget = create!("yearly", 0)
    Events.drain()

    final =
      Enum.reduce(1..365, widget, fn day, current ->
        {:ok, updated} =
          current
          |> Ash.Changeset.for_update(:update, %{value: day})
          |> Ash.update()

        assert [%{value: ^day}] = get_by_name!("yearly")
        assert [%{value: ^day}] = get_by_name!("yearly")
        assert Events.drain() == [:invalidate, :miss, :hit]

        updated
      end)

    assert final.value == 365

    entries = Enum.count(Process.get_keys(), &match?({:ash_cache_entry, :ash_cache, _}, &1))
    assert entries <= AshCache.Store.Adapters.ProcessLocal.max_entries_per_store()
  end

  test "Ash.get for two different records does not collide in the cache" do
    first = create!("first")
    second = create!("second")
    Events.drain()

    assert Ash.get!(CachedWidget, first.id).name == "first"
    assert Ash.get!(CachedWidget, second.id).name == "second"
    assert Events.drain() == [:miss, :miss]

    assert Ash.get!(CachedWidget, first.id).name == "first"
    assert Events.drain() == [:hit]
  end

  test "queries that differ only by limit or sort do not collide in the cache" do
    create!("a", 1)
    create!("b", 2)
    Events.drain()

    limited = fn -> CachedWidget |> Ash.Query.limit(1) |> Ash.read!() end

    assert length(limited.()) == 1
    assert length(Ash.read!(CachedWidget)) == 2

    descending =
      CachedWidget
      |> Ash.Query.sort(value: :desc)
      |> Ash.read!()

    assert Enum.map(descending, & &1.value) == [2, 1]
    assert Events.drain() == [:miss, :miss, :miss]

    assert length(limited.()) == 1
    assert length(Ash.read!(CachedWidget)) == 2
    assert Events.drain() == [:hit, :hit]
  end

  test "each cached read is stored with its own ttl" do
    TwoTtlWidget
    |> Ash.Changeset.for_create(:create, %{name: "ttl"})
    |> Ash.create!()

    before_ms = System.monotonic_time(:millisecond)
    Ash.read!(Ash.Query.for_read(TwoTtlWidget, :get_by_name, %{name: "ttl"}))
    Ash.read!(Ash.Query.for_read(TwoTtlWidget, :paged))
    after_ms = System.monotonic_time(:millisecond)

    lifetimes =
      for {{:ash_cache_entry, :ash_cache, _key}, {_records, expires_at}} <- Process.get(),
          is_integer(expires_at),
          do: expires_at

    assert length(lifetimes) == 2
    [short, long] = Enum.sort(lifetimes)
    assert short in (before_ms + to_timeout(minute: 1))..(after_ms + to_timeout(minute: 1))
    assert long in (before_ms + to_timeout(hour: 1))..(after_ms + to_timeout(hour: 1))
  end
end
