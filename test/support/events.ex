defmodule AshCache.Test.Events do
  @moduledoc """
  Reads the cache events captured by `AshCache.Testing.capture_events/0`
  out of the test's mailbox, oldest first, so a test can assert the exact
  sequence of hits, misses and invalidations its own calls caused.
  """

  def drain(events \\ []) do
    receive do
      {:ash_cache, kind, _metadata} -> drain([kind | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  @doc "Like `drain/0`, keeping only the events of reads of `resource`."
  def drain_for(resource, events \\ []) do
    receive do
      {:ash_cache, kind, %{resource: ^resource}} -> drain_for(resource, [kind | events])
      {:ash_cache, _kind, _metadata} -> drain_for(resource, events)
    after
      0 -> Enum.reverse(events)
    end
  end
end
