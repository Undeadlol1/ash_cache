defmodule AshCache.ContextGapsTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Events
  alias AshCache.Test.ViewerWidget

  setup do
    AshCache.Testing.capture_events()
  end

  test "an actor given only to Ash.read! never shares an entry with another actor" do
    query = Ash.Query.for_read(ViewerWidget, :with_viewer)

    assert [%{name: "alice"}] = Ash.read!(query, actor: %{id: "alice"})
    assert [%{name: "bob"}] = Ash.read!(query, actor: %{id: "bob"})
    assert [%{name: "alice"}] = Ash.read!(query, actor: %{id: "alice"})
  end

  test "set_context bypass applied after for_read still skips the cache" do
    CachedWidget
    |> Ash.Changeset.for_create(:create, %{name: "x", value: 1})
    |> Ash.create!()

    Events.drain()

    query = Ash.Query.set_context(Ash.Query.for_read(CachedWidget, :read), %{ash_cache: :bypass})

    Ash.read!(query)
    Ash.read!(query)
    assert Events.drain() == []
  end
end
