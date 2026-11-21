defmodule AshCache.AfterActionHooksTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.ScoredWidget

  for action <- [:hook_then_cache, :cache_then_hook] do
    test "#{action}: a cache hit returns what the uncached read returned, hooks run once" do
      Ash.create!(ScoredWidget, %{score: 1})

      assert [%{score: 101}] = Ash.read!(ScoredWidget, action: unquote(action))
      assert_received :hook_ran
      assert [%{score: 101}] = Ash.read!(ScoredWidget, action: unquote(action))
      assert_received :hook_ran
      refute_received :hook_ran
    end
  end
end
