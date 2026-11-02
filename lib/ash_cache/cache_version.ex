defmodule AshCache.CacheVersion do
  @moduledoc """
  Per-resource cache version counter, stored in the same store
  as the cached entries.

  Every cache key embeds the resource's current cache version, so bumping the
  counter makes every previously cached entry unreachable in O(1) — the
  invalidation strategy for writes. Orphaned entries age out via their TTL.

  The one rule everything here follows: **a cache version value is used once
  and never comes back.** Old entries can only be reached again through
  their old cache version, so as long as no old value returns, no old entry
  does — whatever the store loses, evicts or restarts.

  Every value is 128 random bits, never a count. A count read-then-incremented
  would let two writers both write N+1, and a reader that derived its key
  between their commits could cache data missing the second write under a
  cache version that never changes again. A count, or a node-local unique
  integer, also starts over: after a node restart against a store that
  outlived it (Redis), or after the store lost the counter. Random values
  repeat neither.

  A missing counter — a fresh store, or one that lost it to eviction, a
  restart, or a server leaving a distributed cache — is therefore not zero
  but a brand-new value, written back so later reads share it. Two readers
  finding it missing at once may each write their own; the last write wins
  and the other's entries are merely wasted. Neither is an old value.

  A bump writes a new value. If the store refuses, the bump deletes the
  counter instead, which makes the next read pick a new value; only when the
  store refuses both does the bump report an error. A store *error* on read
  answers a fresh value that is never written, so every key misses while the
  store is unhealthy — a burst of reads, never stale data.

  The counter is still stored with `never_evict: true` and `ttl: :infinity`, so a
  store that drops entries to stay within a bound keeps it: losing it is
  safe, but costs every cached read of the resource.
  """

  alias AshCache.Store

  @doc "An opaque value: equal between two calls only while no write happened in between."
  @spec current(atom(), module()) :: term()
  def current(store, resource) do
    case Store.get(store, counter_key(resource)) do
      {:ok, nil} ->
        version = new_value()
        _ = put(store, resource, version)
        version

      {:ok, version} ->
        version

      {:error, _reason} ->
        new_value()
    end
  end

  @spec bump(atom(), module()) :: :ok | {:error, term()}
  def bump(store, resource) do
    result =
      with {:error, _reason} <- put(store, resource, new_value()) do
        Store.delete(store, counter_key(resource))
      end

    if result == :ok do
      :telemetry.execute([:ash_cache, :invalidate], %{}, %{resource: resource, store: store})
    end

    result
  end

  defp put(store, resource, version) do
    Store.put(store, counter_key(resource), version, ttl: :infinity, never_evict: true)
  end

  defp new_value, do: :crypto.strong_rand_bytes(16)

  defp counter_key(resource), do: {:ash_cache_version, resource}
end
