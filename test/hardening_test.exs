defmodule AshCache.HardeningTest do
  use ExUnit.Case, async: true

  require Ash.Expr

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Events
  alias AshCache.Test.GuardedWidget
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.TwoTtlWidget

  @distinct_names_between_writes 50

  setup do
    AshCache.Testing.capture_events()
  end

  defp create!(name, quantity), do: create_widget!(CachedWidget, name, quantity)

  defp create_widget!(resource, name, quantity) do
    resource
    |> Ash.Changeset.for_create(:create, %{name: name, quantity: quantity})
    |> Ash.create!()
  end

  defp get_by_name!(name), do: get_widget_by_name!(CachedWidget, name)

  defp get_widget_by_name!(resource, name) do
    resource
    |> Ash.Query.for_read(:get_by_name, %{name: name})
    |> Ash.read!()
  end

  defp cached_entries do
    for {{:ash_cache_entry, :ash_cache, _key}, {_records, _expires_at}} = entry <- Process.get(),
        do: entry
  end

  defp prime_read_cache do
    create!("a", 1)
    create!("b", 2)
    assert length(Ash.read!(CachedWidget)) == 2
    assert length(Ash.read!(CachedWidget)) == 2
    assert Events.drain() == [:invalidate, :invalidate, :miss, :hit]
  end

  describe "bulk writes invalidate cached reads" do
    for strategy <- [:atomic, :stream, :atomic_batches] do
      test "a bulk update with the #{strategy} strategy" do
        prime_read_cache()

        bulk_result =
          Ash.bulk_update(CachedWidget, :update, %{quantity: 9}, strategy: [unquote(strategy)])

        assert bulk_result.status == :success
        assert Enum.uniq(Events.drain()) == [:invalidate]

        assert Enum.map(Ash.read!(CachedWidget), & &1.quantity) == [9, 9]
        assert Events.drain() == [:miss]
      end

      test "a bulk destroy with the #{strategy} strategy" do
        prime_read_cache()

        bulk_result = Ash.bulk_destroy(CachedWidget, :destroy, %{}, strategy: [unquote(strategy)])
        assert bulk_result.status == :success
        assert Enum.uniq(Events.drain()) == [:invalidate]

        assert Ash.read!(CachedWidget) == []
        assert Events.drain() == [:miss]
      end
    end

    test "a bulk create" do
      prime_read_cache()

      bulk_result = Ash.bulk_create([%{name: "c"}, %{name: "d"}], CachedWidget, :create)
      assert bulk_result.status == :success
      assert Enum.uniq(Events.drain()) == [:invalidate]

      assert length(Ash.read!(CachedWidget)) == 4
      assert Events.drain() == [:miss]
    end

    test "a single atomic update" do
      prime_read_cache()
      [widget | _] = CachedWidget |> Ash.Query.sort(name: :asc) |> Ash.read!()
      Events.drain()

      widget
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.atomic_update(:quantity, Ash.Expr.expr(quantity + 100))
      |> Ash.update!()

      assert Enum.uniq(Events.drain()) == [:invalidate]
      assert Enum.sort(Enum.map(Ash.read!(CachedWidget), & &1.quantity)) == [2, 101]
      assert Events.drain() == [:miss]
    end
  end

  test "invalidating by hand makes the next identical read a miss" do
    create!("a", 1)
    get_by_name!("a")
    get_by_name!("a")
    Events.drain()

    :ok = AshCache.invalidate(CachedWidget)
    assert Enum.uniq(Events.drain()) == [:invalidate]

    assert [%{quantity: 1}] = get_by_name!("a")
    assert Events.drain() == [:miss]
  end

  test "reads that select different fields do not share a cache entry" do
    create!("a", 5)
    Events.drain()

    assert [%{quantity: 5}] = Ash.read!(CachedWidget)
    narrowed = Ash.read!(Ash.Query.select(CachedWidget, [:name]))
    assert [%{name: "a"}] = narrowed
    assert Events.drain() == [:miss, :miss]

    assert [%{quantity: 5}] = Ash.read!(CachedWidget)
    assert Events.drain() == [:hit]
  end

  test "two actors reading the same action each get their own cache entry" do
    create_widget!(GuardedWidget, "shared", 0)
    Events.drain()

    first = %{id: "first"}
    second = %{id: "second"}

    assert [_widget] = Ash.read!(GuardedWidget, actor: first)
    assert [_widget] = Ash.read!(GuardedWidget, actor: second)
    assert Events.drain() == [:miss, :miss]

    assert [_widget] = Ash.read!(GuardedWidget, actor: first)
    assert Events.drain() == [:hit]
  end

  describe "per-read ttl" do
    defp expire_shortest_lived_entry do
      {entry_key, {records, _expires_at}} =
        cached_entries()
        |> Enum.min_by(fn {_key, {_records, expires_at}} -> expires_at end)

      Process.put(entry_key, {records, System.monotonic_time(:millisecond) - 1})
    end

    test "an expired short-lived read misses while the long-lived read is still a hit" do
      create_widget!(TwoTtlWidget, "ttl", 0)
      read_long_lived = fn -> get_widget_by_name!(TwoTtlWidget, "ttl") end
      read_short_lived = fn -> Ash.read!(Ash.Query.for_read(TwoTtlWidget, :paged)) end

      read_long_lived.()
      read_short_lived.()
      Events.drain()
      expire_shortest_lived_entry()

      read_short_lived.()
      read_long_lived.()

      assert Events.drain() == [:miss, :hit]
    end
  end

  describe "caching empty results" do
    test "a cached empty result is replaced once a matching record is created" do
      assert [] = get_widget_by_name!(PartiallyCachedWidget, "late")
      assert [] = get_widget_by_name!(PartiallyCachedWidget, "late")
      assert Events.drain() == [:miss, :hit]

      create_widget!(PartiallyCachedWidget, "late", 3)
      assert Enum.uniq(Events.drain()) == [:invalidate]

      assert [%{quantity: 3}] = get_widget_by_name!(PartiallyCachedWidget, "late")
      assert Events.drain() == [:miss]
    end
  end

  test "empty results are re-read every time when empty caching is off" do
    assert [] = get_by_name!("absent")
    assert [] = get_by_name!("absent")
    assert Events.drain() == [:miss, :miss]

    create!("absent", 4)
    Events.drain()

    assert [%{quantity: 4}] = get_by_name!("absent")
  end

  test "fifty distinct cached queries between writes stay bounded and the last write still reads fresh" do
    names = Enum.map(1..@distinct_names_between_writes, &"product-#{&1}")
    widgets = Map.new(names, &{&1, create!(&1, 1)})

    for name <- names, do: assert([%{quantity: 1}] = get_by_name!(name))

    last = List.last(names)
    assert [%{quantity: 1}] = get_by_name!(last)
    assert Events.drain() |> Enum.count(&(&1 == :hit)) == 1

    widgets[last]
    |> Ash.Changeset.for_update(:update, %{quantity: 2})
    |> Ash.update!()

    assert [%{quantity: 2}] = get_by_name!(last)

    for name <- List.delete(names, last), do: assert([%{quantity: 1}] = get_by_name!(name))

    bound = AshCache.Store.Adapters.ProcessLocal.max_entries_per_store()
    assert length(cached_entries()) <= bound
  end
end
