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
end
