defmodule AshCache.Preparations.ReadThroughTest do
  use ExUnit.Case, async: true

  alias AshCache.Generation
  alias AshCache.Preparations.ReadThrough
  alias AshCache.Test.Widget

  defmodule FakeUser do
    @moduledoc false
    defstruct [:id]
  end

  setup do
    store = :"read_through_store_#{System.unique_integer([:positive])}"
    {:ok, store: store, opts: [store: store, ttl: to_timeout(hour: 1), cache_empty?: false]}
  end

  defp query_for(name) do
    Ash.Query.for_read(Widget, :get_by_name, %{name: name})
  end

  defp answer_from_cache(query) do
    query.context[:private][:action_result]
  end

  defp run_before_action(prepared_query) do
    Enum.reduce(prepared_query.before_action, prepared_query, fn hook, query ->
      hook.(query)
    end)
  end

  defp prepare_and_run(query, opts, context) do
    query
    |> ReadThrough.prepare(opts, context)
    |> run_before_action()
  end

  defp complete_read(prepared_query, records) do
    [hook] = prepared_query.after_action
    assert {:ok, ^records} = hook.(prepared_query, records)
    :ok
  end

  test "a miss registers an after-action hook and leaves the read to the data layer", %{
    opts: opts
  } do
    prepared = prepare_and_run(query_for("a"), opts, %{})

    assert answer_from_cache(prepared) == nil
    assert length(prepared.after_action) == 1
  end

  test "completing a read caches it, and the next identical read is a hit", %{opts: opts} do
    records = [%{name: "a", quantity: 1}]

    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, records)

    hit = prepare_and_run(query_for("a"), opts, %{})
    assert answer_from_cache(hit) == {:ok, records}
  end

  test "queries that differ only by filter do not share cache entries", %{opts: opts} do
    require Ash.Query

    unfiltered = Ash.Query.for_read(Widget, :read, %{})
    filtered_a = Ash.Query.filter(unfiltered, name == "a")
    filtered_b = Ash.Query.filter(unfiltered, name == "b")

    prepared = prepare_and_run(filtered_a, opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    assert answer_from_cache(prepare_and_run(filtered_a, opts, %{})) == {:ok, [%{name: "a"}]}
    assert answer_from_cache(prepare_and_run(filtered_b, opts, %{})) == nil
  end

  test "queries that differ only by limit do not share cache entries", %{opts: opts} do
    unlimited = Ash.Query.for_read(Widget, :read, %{})
    limited = Ash.Query.limit(unlimited, 1)

    prepared = prepare_and_run(limited, opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    assert answer_from_cache(prepare_and_run(unlimited, opts, %{})) == nil
  end

  test "different arguments do not share cache entries", %{opts: opts} do
    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    other_name = prepare_and_run(query_for("b"), opts, %{})
    assert answer_from_cache(other_name) == nil
  end

  test "empty results are not cached by default", %{opts: opts} do
    prepared = prepare_and_run(query_for("missing"), opts, %{})
    :ok = complete_read(prepared, [])

    still_miss = prepare_and_run(query_for("missing"), opts, %{})
    assert answer_from_cache(still_miss) == nil
  end

  test "empty results are cached when empty caching is on", %{opts: opts} do
    opts = Keyword.put(opts, :cache_empty?, true)

    prepared = prepare_and_run(query_for("missing"), opts, %{})
    :ok = complete_read(prepared, [])

    hit = prepare_and_run(query_for("missing"), opts, %{})
    assert answer_from_cache(hit) == {:ok, []}
  end

  test "bypass context skips caching entirely", %{opts: opts} do
    query = Ash.Query.set_context(query_for("a"), %{ash_cache: :bypass})

    prepared = prepare_and_run(query, opts, %{})

    assert prepared.after_action == []
    assert answer_from_cache(prepared) == nil
  end

  test "a bulk write's target-selection query is never cached or hooked", %{opts: opts} do
    for bulk_action <- [:bulk_update, :bulk_destroy] do
      query = Ash.Query.set_context(query_for("a"), %{query_for: bulk_action})

      prepared = prepare_and_run(query, opts, %{})

      assert prepared.before_action == []
      assert prepared.after_action == []
      assert answer_from_cache(prepared) == nil
    end
  end

  test "one actor's cached entry is invisible to another actor", %{opts: opts} do
    first_actor = %FakeUser{id: "user-1"}
    second_actor = %FakeUser{id: "user-2"}

    prepared = prepare_and_run(query_for("a"), opts, %{actor: first_actor})
    :ok = complete_read(prepared, [%{name: "a", owner: "user-1"}])

    assert answer_from_cache(prepare_and_run(query_for("a"), opts, %{actor: first_actor})) ==
             {:ok, [%{name: "a", owner: "user-1"}]}

    assert answer_from_cache(prepare_and_run(query_for("a"), opts, %{actor: second_actor})) ==
             nil
  end

  test "bumping the generation turns hits back into misses", %{store: store, opts: opts} do
    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    :ok = Generation.bump(store, Widget)

    assert answer_from_cache(prepare_and_run(query_for("a"), opts, %{})) == nil
  end
end
