defmodule AshCache.Generation do
  @moduledoc """
  Per-resource cache generation (epoch) counter, stored in the same store
  as the cached entries.

  Every cache key embeds the resource's current generation, so bumping the
  counter makes every previously cached entry unreachable in O(1) — the
  invalidation strategy for writes. Orphaned entries age out via their TTL.

  The one rule everything here follows: **a generation value is used once
  and never comes back.** Old entries can only be reached again through
  their old generation, so as long as no old value returns, no old entry
  does — whatever the store loses, evicts or restarts.

  Every value is 128 random bits, never a count. A count read-then-incremented
  would let two writers both write N+1, and a reader that derived its key
  between their commits could cache data missing the second write under a
  generation that never changes again. A count, or a node-local unique
  integer, also starts over: after a node restart against a store that
  outlived it (Redis), or after the store lost the counter. Random values
  repeat neither.

  A missing counter — a fresh store, or one that lost it to eviction, a
  restart, or a server leaving a distributed cache — is therefore not zero
  but a brand-new value, written back so later reads share it. Two readers
  finding it missing at once on one server share one new value (see
  `AshCache.Coalesce`); on two servers each may write its own, the last write
  wins and the other's entries are merely wasted. Neither is an old value.

  A bump writes a new value. If the store refuses, the bump deletes the
  counter instead, which makes the next read pick a new value; only when the
  store refuses both does the bump report an error. A store *error* on read
  answers a fresh value that is never written, so every key misses while the
  store is unhealthy — a burst of reads, never stale data.

  The counter is still stored with `pin: true` and `ttl: :infinity`, so a
  store that drops entries to stay within a bound keeps it: losing it is
  safe, but costs every cached read of the resource.
  """

  alias AshCache.Coalesce
  alias AshCache.Store

  @doc "An opaque value: equal between two calls only while no write happened in between."
  @spec current(atom(), module()) :: term()
  def current(store, resource) do
    case Store.get(store, counter_key(resource)) do
      {:ok, nil} ->
        replace_missing(store, resource)

      {:ok, generation} ->
        generation

      {:error, _reason} ->
        new_value()
    end
  end

  @spec bump(atom(), module()) :: :ok | {:error, term()}
  def bump(store, resource) do
    result =
      with {:error, _reason} <- put(store, resource, new_value()) do
        Store.del(store, counter_key(resource))
      end

    if result == :ok do
      :telemetry.execute([:ash_cache, :invalidate], %{}, %{resource: resource, store: store})
    end

    result
  end

  # Readers on this server that find the counter missing at the same time
  # share one new value, or each would build its own keys and all of them
  # would read the data layer.
  defp replace_missing(store, resource) do
    key = {:ash_cache_missing_generation, store, resource}

    case Coalesce.join(key) do
      {:shared, generation} ->
        generation

      :retry ->
        current(store, resource)

      _lead_or_alone ->
        # Looks once more: another reader may have just written one.
        generation =
          case Store.get(store, counter_key(resource)) do
            {:ok, generation} when not is_nil(generation) ->
              generation

            _missing_or_error ->
              generation = new_value()
              _ = put(store, resource, generation)
              generation
          end

        Coalesce.release(key, {:ok, generation})
        generation
    end
  end

  defp put(store, resource, generation) do
    Store.put(store, counter_key(resource), generation, ttl: :infinity, pin: true)
  end

  defp new_value, do: :crypto.strong_rand_bytes(16)

  defp counter_key(resource), do: {:ash_cache_generation, resource}
end
