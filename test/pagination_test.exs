defmodule AshCache.PaginationTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.Events
  alias AshCache.Test.PagedWidget

  setup do
    AshCache.Testing.capture_events()
    for name <- ~w(a b c d e), do: Ash.create!(PagedWidget, %{name: name})
    :ok
  end

  defp names(rows), do: Enum.map(rows, & &1.name)

  defp page(action, opts), do: Ash.read!(PagedWidget, action: action, page: opts)

  test "keyset pages after a cursor match the uncached rows, and are cached per cursor" do
    first = page(:keyset, limit: 2)
    assert names(first.results) == ~w(a b)
    cursor = List.last(first.results).__metadata__.keyset

    for _ <- 1..2 do
      second = page(:keyset, limit: 2, after: cursor)
      assert names(second.results) == ~w(c d)
      assert second.more?
    end

    assert Enum.reject(Events.drain(), &(&1 == :invalidate)) == [:miss, :miss, :hit]

    # A hit serves the same cursors, so paging on from it still works.
    last =
      page(:keyset,
        limit: 2,
        after: List.last(page(:keyset, limit: 2, after: cursor).results).__metadata__.keyset
      )

    assert names(last.results) == ~w(e)
    refute last.more?
  end

  test "offset pages with a count return the same count on a hit, per offset" do
    for _ <- 1..2 do
      one = page(:offset, limit: 2, offset: 0, count: true)
      assert {names(one.results), one.count, one.more?} == {~w(a b), 5, true}
      two = page(:offset, limit: 2, offset: 2, count: true)
      assert {names(two.results), two.count, two.more?} == {~w(c d), 5, true}
    end

    uncounted = page(:offset, limit: 2, offset: 0)
    assert uncounted.count == nil
    assert Enum.count(Events.drain(), &(&1 == :hit)) == 2
  end

  test "Ash.stream! over a cached read returns every row, every time" do
    for _ <- 1..2 do
      assert PagedWidget
             |> Ash.stream!(action: :keyset, batch_size: 2)
             |> Enum.map(& &1.name)
             |> Enum.sort() == ~w(a b c d e)
    end

    for _ <- 1..2 do
      assert PagedWidget
             |> Ash.stream!(action: :offset, batch_size: 2, stream_with: :offset)
             |> Enum.map(& &1.name)
             |> Enum.sort() == ~w(a b c d e)
    end
  end
end
