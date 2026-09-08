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

  defp cached_result(query) do
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

  test "a miss registers an after_action hook and does not set a result", %{opts: opts} do
    prepared = prepare_and_run(query_for("a"), opts, %{})

    assert cached_result(prepared) == nil
    assert length(prepared.after_action) == 1
  end

  test "completing a read caches, and the next prepare is a hit", %{opts: opts} do
    records = [%{name: "a", value: 1}]

    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, records)

    hit = prepare_and_run(query_for("a"), opts, %{})
    assert cached_result(hit) == {:ok, records}
  end

  test "queries that differ only by filter do not share cache entries", %{opts: opts} do
    require Ash.Query

    base = Ash.Query.for_read(Widget, :read, %{})
    filtered_a = Ash.Query.filter(base, name == "a")
    filtered_b = Ash.Query.filter(base, name == "b")

    prepared = prepare_and_run(filtered_a, opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    assert cached_result(prepare_and_run(filtered_a, opts, %{})) == {:ok, [%{name: "a"}]}
    assert cached_result(prepare_and_run(filtered_b, opts, %{})) == nil
  end

  test "queries that differ only by limit do not share cache entries", %{opts: opts} do
    base = Ash.Query.for_read(Widget, :read, %{})
    limited = Ash.Query.limit(base, 1)

    prepared = prepare_and_run(limited, opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    assert cached_result(prepare_and_run(base, opts, %{})) == nil
  end

  test "different arguments do not share cache entries", %{opts: opts} do
    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    other = prepare_and_run(query_for("b"), opts, %{})
    assert cached_result(other) == nil
  end

  test "empty results are not cached by default", %{opts: opts} do
    prepared = prepare_and_run(query_for("missing"), opts, %{})
    :ok = complete_read(prepared, [])

    still_miss = prepare_and_run(query_for("missing"), opts, %{})
    assert cached_result(still_miss) == nil
  end

  test "cache_empty?: true caches empty results", %{opts: opts} do
    opts = Keyword.put(opts, :cache_empty?, true)

    prepared = prepare_and_run(query_for("missing"), opts, %{})
    :ok = complete_read(prepared, [])

    hit = prepare_and_run(query_for("missing"), opts, %{})
    assert cached_result(hit) == {:ok, []}
  end

  test "bypass context skips caching entirely", %{opts: opts} do
    query = Ash.Query.set_context(query_for("a"), %{ash_cache: :bypass})

    prepared = prepare_and_run(query, opts, %{})

    assert prepared.after_action == []
    assert cached_result(prepared) == nil
  end

  test "a bulk write's target-selection query is never cached or hooked", %{opts: opts} do
    for query_for <- [:bulk_update, :bulk_destroy] do
      query = Ash.Query.set_context(query_for("a"), %{query_for: query_for})

      prepared = prepare_and_run(query, opts, %{})

      assert prepared.before_action == []
      assert prepared.after_action == []
      assert cached_result(prepared) == nil
    end
  end

  test "one actor's cached entry is invisible to another actor", %{opts: opts} do
    first_actor = %FakeUser{id: "user-1"}
    second_actor = %FakeUser{id: "user-2"}

    prepared = prepare_and_run(query_for("a"), opts, %{actor: first_actor})
    :ok = complete_read(prepared, [%{name: "a", owner: "user-1"}])

    assert cached_result(prepare_and_run(query_for("a"), opts, %{actor: first_actor})) ==
             {:ok, [%{name: "a", owner: "user-1"}]}

    assert cached_result(prepare_and_run(query_for("a"), opts, %{actor: second_actor})) ==
             nil
  end

  test "bumping the generation turns hits back into misses", %{store: store, opts: opts} do
    prepared = prepare_and_run(query_for("a"), opts, %{})
    :ok = complete_read(prepared, [%{name: "a"}])

    :ok = Generation.bump(store, Widget)

    assert cached_result(prepare_and_run(query_for("a"), opts, %{})) == nil
  end
end
