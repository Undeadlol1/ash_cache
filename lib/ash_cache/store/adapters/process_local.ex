defmodule AshCache.Store.Adapters.ProcessLocal do
  @moduledoc """
  Process-dictionary adapter: every process sees its own private cache,
  which makes `async: true` tests isolated with zero setup.
  """

  @behaviour AshCache.Store.Adapter

  @tracked_keys_prefix :ash_cache_keys
  @pinned_keys_prefix :ash_cache_pinned_keys
  @entry_prefix :ash_cache_entry

  # Generation-based invalidation strands old entries: nothing reads them
  # again, so their TTL is never checked and they accumulate for the life of
  # the process, slowing every process-dictionary walk. Overflowing the
  # bound resets the store — a burst of misses, never stale data.
  #
  # "Never stale data" only holds because `pin: true` entries are exempt from
  # the bound. The one such entry is the resource's generation counter: reset
  # it and `AshCache.Generation.current/2` self-heals to zero, which is not a
  # miss but a rollback — every key written under an earlier generation becomes
  # reachable again. Dead result sets are what the bound is for, and none of
  # those are pinned.
  #
  # The bound is therefore how much dead weight every write-heavy test drags
  # through garbage collection, and an entry is a whole result set keyed by a
  # whole query shape (~3KB apiece here). At 512 that cost dominated: one
  # write-heavy test in the application this was extracted from ran 36s, of
  # which 20s vanished when the bound came down to 32. A test process needs a
  # working set, not a history, and no test here reads anywhere near 32
  # distinct cached queries inside one generation.
  @max_entries_per_store 32

  @doc false
  def max_entries_per_store, do: @max_entries_per_store

  @impl true
  def get(store, key) do
    case Process.get(entry_key(store, key)) do
      nil ->
        {:ok, nil}

      {value, :infinity} ->
        {:ok, value}

      {value, expires_at_ms} when is_integer(expires_at_ms) ->
        if now_ms() >= expires_at_ms do
          delete_entry(store, key)
          {:ok, nil}
        else
          {:ok, value}
        end
    end
  end

  @impl true
  def put(store, key, value, opts) do
    ttl = Keyword.get(opts, :ttl, :infinity)

    expires_at_ms =
      case ttl do
        :infinity -> :infinity
        ttl_ms when is_integer(ttl_ms) and ttl_ms <= 0 -> now_ms() - 1
        ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> now_ms() + ttl_ms
        _other -> :infinity
      end

    Process.put(entry_key(store, key), {value, expires_at_ms})
    track_key(store, key, Keyword.get(opts, :pin, false))
    :ok
  end

  @impl true
  def del(store, key) do
    delete_entry(store, key)
    :ok
  end

  @impl true
  def clear(store) do
    drop_tracked_entries(store)
    drop_entries(store, pinned_keys(store), pinned_keys_key(store))
  end

  defp track_key(store, key, true) do
    Process.put(pinned_keys_key(store), MapSet.put(pinned_keys(store), key))
  end

  defp track_key(store, key, false) do
    tracked = tracked_keys(store)

    if MapSet.size(tracked) >= @max_entries_per_store and not MapSet.member?(tracked, key) do
      entry = Process.get(entry_key(store, key))
      drop_tracked_entries(store)
      Process.put(entry_key(store, key), entry)
      Process.put(tracked_keys_key(store), MapSet.new([key]))
    else
      Process.put(tracked_keys_key(store), MapSet.put(tracked, key))
    end
  end

  defp drop_tracked_entries(store) do
    drop_entries(store, tracked_keys(store), tracked_keys_key(store))
  end

  defp drop_entries(store, keys, tracking_key) do
    Enum.each(keys, &Process.delete(entry_key(store, &1)))
    Process.delete(tracking_key)
    :ok
  end

  defp delete_entry(store, key) do
    Process.delete(entry_key(store, key))
    Process.put(pinned_keys_key(store), MapSet.delete(pinned_keys(store), key))

    remaining = MapSet.delete(tracked_keys(store), key)

    if MapSet.size(remaining) == 0 do
      Process.delete(tracked_keys_key(store))
    else
      Process.put(tracked_keys_key(store), remaining)
    end

    :ok
  end

  defp tracked_keys(store), do: Process.get(tracked_keys_key(store), MapSet.new())

  defp pinned_keys(store), do: Process.get(pinned_keys_key(store), MapSet.new())

  defp tracked_keys_key(store), do: {@tracked_keys_prefix, store}
  defp pinned_keys_key(store), do: {@pinned_keys_prefix, store}
  defp entry_key(store, key), do: {@entry_prefix, store, key}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
