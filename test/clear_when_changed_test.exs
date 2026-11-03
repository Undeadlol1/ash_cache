defmodule AshCache.ClearWhenChangedTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Comment
  alias AshCache.Test.Events
  alias AshCache.Test.Feed
  alias AshCache.Test.Post
  alias AshCache.Test.SelfListedWidget

  setup do
    AshCache.Testing.capture_events()
  end

  defp create!(resource, name) do
    resource
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  # Empty results are not cached, so this adds a row, then reads twice so the
  # result is in the cache, then forgets the events.
  defp prime(resource) do
    create!(resource, "row")
    Events.drain()
    Ash.read!(resource)
    Ash.read!(resource)
    assert Events.drain() == [:miss, :hit]
  end

  defp assert_cleared(resource) do
    Ash.read!(resource)
    assert Events.drain() == [:miss]
  end

  defp assert_still_cached(resource) do
    Ash.read!(resource)
    assert Events.drain() == [:hit]
  end

  test "creating a comment clears the cached post reads" do
    prime(Post)

    create!(Comment, "first")
    assert Events.drain() == [:invalidate]

    assert_cleared(Post)
  end

  test "updating a comment clears the cached post reads" do
    comment = create!(Comment, "first")
    prime(Post)

    comment |> Ash.Changeset.for_update(:update, %{quantity: 2}) |> Ash.update!()
    Events.drain()

    assert_cleared(Post)
  end

  test "destroying a comment clears the cached post reads" do
    comment = create!(Comment, "first")
    prime(Post)

    Ash.destroy!(comment)
    Events.drain()

    assert_cleared(Post)
  end

  describe "bulk writes to a comment clear the cached post reads" do
    test "bulk_create" do
      prime(Post)

      assert %{status: :success} = Ash.bulk_create([%{name: "a"}, %{name: "b"}], Comment, :create)
      Events.drain()

      assert_cleared(Post)
    end

    test "bulk_update" do
      create!(Comment, "first")
      prime(Post)

      assert %{status: :success} = Ash.bulk_update(Comment, :update, %{quantity: 9})
      Events.drain()

      assert_cleared(Post)
    end

    test "bulk_destroy" do
      create!(Comment, "first")
      prime(Post)

      assert %{status: :success} = Ash.bulk_destroy(Comment, :destroy, %{})
      Events.drain()

      assert_cleared(Post)
    end
  end

  test "a comment write that fails leaves the cached post reads alone" do
    prime(Post)

    assert {:error, _invalid} =
             Comment |> Ash.Changeset.for_create(:create, %{}) |> Ash.create()

    assert Events.drain() == []
    assert_still_cached(Post)
  end

  test "a write to a resource Post does not list leaves its cached reads alone" do
    prime(Post)

    create!(CachedWidget, "unrelated")
    Events.drain()

    assert_still_cached(Post)
  end

  test "one comment write clears every resource that lists Comment, in its own store" do
    prime(Post)
    prime(Feed)

    create!(Comment, "first")
    Events.drain()

    assert_cleared(Post)
    assert_cleared(Feed)
  end

  test "a resource that lists itself is still cleared by its own writes" do
    prime(SelfListedWidget)

    create!(SelfListedWidget, "self")
    assert Events.drain() == [:invalidate]

    assert_cleared(SelfListedWidget)
  end

  test "the invalidate event names Comment, the resource that changed" do
    create!(Comment, "first")

    assert_received {:ash_cache, :invalidate, %{resource: Comment, store: :ash_cache}}
    refute_received {:ash_cache, :invalidate, %{resource: Post}}
  end

  test "AshCache.invalidate(Comment) also clears the cached post reads" do
    prime(Post)

    assert AshCache.invalidate(Comment) == :ok
    Events.drain()

    assert_cleared(Post)
  end
end
