defmodule AshCache.Coalesce do
  @moduledoc """
  Lets identical cache misses on one server share a single data-layer read.

  When a popular entry runs out, every request arriving before it is cached
  again would read the data layer. Instead, the first request for a cache
  key becomes the *leader* and reads; the others wait and get its records.
  Requests share a read only when their whole cache key is equal, so actor
  and tenant isolation is the same as for cached entries.

  If the leader's read fails or its process dies, the waiters start over and
  one of them leads the next read. If the leader takes longer than
  `config :ash_cache, rebuild_timeout: ms` (default 5 seconds), each waiter
  reads for itself, so a stuck read never blocks anyone for good.

  This works per server, whatever the store: on several servers, each server
  makes at most one read per key at a time. Built-in options were checked
  first: `Cachex.fetch/4` runs the rebuild in another process, which Ash's
  read hooks cannot hand it, and Nebulex's `fetch_or_store` documents that
  concurrent misses can each run the function.
  """

  @leaders AshCache.Coalesce.Leaders
  @waiters AshCache.Coalesce.Waiters
  @default_timeout to_timeout(second: 5)

  @doc false
  def child_specs do
    [
      Supervisor.child_spec({Registry, keys: :unique, name: @leaders}, id: @leaders),
      Supervisor.child_spec({Registry, keys: :duplicate, name: @waiters}, id: @waiters)
    ]
  end

  @doc """
  Joins the read for `key`. Returns `:lead` when the caller must read and
  then call `release/2`, `{:shared, records}` with the leader's records,
  `:retry` when the leader failed (look in the cache again: another waiter
  may already have rebuilt it, then join again), or `:alone` when the leader
  took too long and the caller should just read.
  """
  @spec join(term()) :: :lead | {:shared, term()} | :retry | :alone
  def join(key) do
    # Registered as a waiter before trying to lead: a leader removes itself
    # before telling its waiters, so whoever sees it still leading is
    # already on the list it tells.
    reply_to = Process.alias()
    {:ok, _} = Registry.register(@waiters, key, reply_to)

    result =
      case Registry.register(@leaders, key, nil) do
        {:ok, _} -> :lead
        {:error, {:already_registered, leader}} -> await(leader, reply_to)
      end

    Registry.unregister_match(@waiters, key, reply_to)
    # Drops any answer still on its way, so none is left in the mailbox.
    Process.unalias(reply_to)
    flush(reply_to)

    result
  end

  @doc "Tells everyone waiting on `key` the leader's outcome: `{:ok, records}` or `:failed`."
  @spec release(term(), {:ok, term()} | :failed) :: :ok
  def release(key, outcome) do
    Registry.unregister(@leaders, key)

    Registry.dispatch(@waiters, key, fn waiters ->
      for {_pid, reply_to} <- waiters, do: send(reply_to, {reply_to, outcome})
    end)
  end

  defp await(leader, reply_to) do
    monitor = Process.monitor(leader)

    result =
      receive do
        {^reply_to, {:ok, records}} -> {:shared, records}
        {^reply_to, :failed} -> :retry
        {:DOWN, ^monitor, :process, _, _} -> :retry
      after
        Application.get_env(:ash_cache, :rebuild_timeout, @default_timeout) -> :alone
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp flush(reply_to) do
    receive do
      {^reply_to, _} -> flush(reply_to)
    after
      0 -> :ok
    end
  end
end
