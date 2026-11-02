defmodule AshCache.ContextGapsTest do
  use ExUnit.Case, async: true

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
end
