defmodule AshCache.Generation do
  @moduledoc """
  Per-resource cache generation (epoch) counter, stored in the same store
  as the cached entries.

  Every cache key embeds the resource's current generation, so bumping the
  counter makes every previously cached entry unreachable in O(1) — the
  invalidation strategy for writes. Orphaned entries age out via their TTL.

  The bump is read-then-write, not atomic: two concurrent bumps may land on
  the same new value. That is safe — invalidation only requires that the
  generation differs from the one embedded in pre-write cache keys.

  A missing counter (a fresh store) self-heals to zero. That is only safe
  because the counter is stored with `pin: true`, so a store which drops
  entries to stay within a capacity bound cannot drop this one: healing to
  zero after a bump would make pre-bump keys reachable again — stale data,
  not the burst of misses a fresh store costs.

  A store *error* is not a missing counter and must not heal the same way:
  the counter may well be there, and above zero. Those reads answer with an
  unreachable generation instead, so every key misses while the store is
  unhealthy — a burst of reads, never a rollback to stale data.
  """

  alias AshCache.Store

  @spec current(atom(), module()) :: non_neg_integer()
  def current(store, resource) do
    case Store.get(store, counter_key(resource)) do
      {:ok, generation} when is_integer(generation) -> generation
      {:error, _reason} -> :erlang.unique_integer([:positive])
      _missing -> 0
    end
  end

  @spec bump(atom(), module()) :: :ok | {:error, term()}
  def bump(store, resource) do
    result =
      Store.put(store, counter_key(resource), current(store, resource) + 1,
        ttl: :infinity,
        pin: true
      )

    if result == :ok do
      :telemetry.execute([:ash_cache, :invalidate], %{}, %{resource: resource, store: store})
    end

    result
  end

  defp counter_key(resource), do: {:ash_cache_generation, resource}
end
