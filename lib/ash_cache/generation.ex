defmodule AshCache.Generation do
  @moduledoc """
  Per-resource cache generation (epoch) counter, stored in the same store
  as the cached entries.

  Every cache key embeds the resource's current generation, so bumping the
  counter makes every previously cached entry unreachable in O(1) — the
  invalidation strategy for writes. Orphaned entries age out via their TTL.

  A bump never reads the counter: it writes a fresh unique token
  (`{node(), unique_integer}`), so two concurrent bumps can never land on the
  same value. A read-then-increment would let two writers both write N+1, and
  a reader that derived its key between their commits could cache data
  missing the second write under a generation that never changes again.
  With unique tokens, a key derived after the last bump uses the last bump's
  token, so only a reader that started after every commit can cache under it.
  The node is part of the token so stores shared between nodes cannot
  produce colliding values.

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

  @doc "`0` for a fresh store, otherwise an opaque token: equal only until the next bump."
  @spec current(atom(), module()) :: term()
  def current(store, resource) do
    case Store.get(store, counter_key(resource)) do
      {:ok, nil} -> 0
      {:ok, generation} -> generation
      {:error, _reason} -> :erlang.unique_integer([:positive])
    end
  end

  @spec bump(atom(), module()) :: :ok | {:error, term()}
  def bump(store, resource) do
    result =
      Store.put(store, counter_key(resource), fresh_token(), ttl: :infinity, pin: true)

    if result == :ok do
      :telemetry.execute([:ash_cache, :invalidate], %{}, %{resource: resource, store: store})
    end

    result
  end

  defp fresh_token, do: {node(), :erlang.unique_integer([:monotonic, :positive])}

  defp counter_key(resource), do: {:ash_cache_generation, resource}
end
