# AshCache

Declarative read-through caching for Ash resources.

Not on Hex yet:

```elixir
def deps do
  [{:ash_cache, github: "Undeadlol1/ash_cache"}]
end
```

Then supervise the stores, once, and every cached resource is wired:

```elixir
children = [
  {AshCache.Supervisor, otp_app: :my_app}
]
```

## The whole pitch

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
  end
end
```

That empty block gives you:

| Concern | Default |
|---|---|
| What is cached | every read action |
| Cache key | action + the full query shape (arguments, filter, sort, limit, offset, page, distinct, select, load) + **actor** + **tenant** |
| TTL | 1 hour |
| Store | one app-wide `:ash_cache` Cachex, auto-started by `AshCache.Supervisor` |
| Invalidation | automatic — every create/update/destroy bumps the resource's generation after commit |
| Empty results | not cached (no negative-cache poisoning) |
| Tests | isolated per process (`AshCache.Store.Adapters.ProcessLocal` in test config) |

## What it expects from Ash

Two Ash settings this depends on, rather than merely preferring:

```elixir
config :ash,
  # Generation bumping runs in after_transaction, and the read side's
  # hooks have to observe writes in the order they happened.
  read_action_after_action_hooks_in_order?: true,
  # Actor-scoped cache keys only mean anything if a policy-filtered read
  # returns rows rather than a static forbidden error.
  policies: [no_filter_static_forbidden_reads?: false]
```

The store adapter is chosen with `config :ash_cache, adapter: module`.
Tests usually want `AshCache.Store.Adapters.ProcessLocal`, which gives every
process its own cache and so makes `async: true` isolated by construction.

Ash needs a SAT solver (`:picosat_elixir` or `:simple_sat`) to evaluate
policies. That is a dependency of your app, not of this package.

## How invalidation works

Every key embeds a per-resource **generation counter** (`AshCache.Generation`).
A successful write bumps it in `after_transaction` — never `after_action`, so
a rolled-back write cannot leave stale cache behind. Old-generation entries
become unreachable in O(1) and age out via TTL. There is deliberately no
per-key eviction in v1: with auto-derived keys a write cannot know every
query shape that cached it.

## Escape hatches, in increasing depth

1. Options in the block:

   ```elixir
   cache do
     ttl :timer.minutes(5)
     store :products_cache
     reads [:get_by_sku]        # cache only these reads
     cache_empty? true
     adapter_options limit: 1_000  # raw passthrough to the adapter's put/4

     # write-through: after every successful create/update, re-run this read
     # (args taken from the written record) so the fresh value is cached
     # before anyone asks. Warming re-executes the real read action, so it
     # shares the normal key derivation and authorization. It runs
     # synchronously in after_transaction, so each declaration costs the
     # writer one extra read. Failures only log — the generation bump
     # already guarantees correctness.
     warm :get_by_sku, args: [sku: :sku], actor: {MyApp.SystemActor, :system, []}
   end
   ```

2. Per query: `Ash.Query.set_context(query, %{ash_cache: :bypass})`.
3. Runtime helpers: `AshCache.invalidate(resource)`, `AshCache.clear_store(store)`.
4. Swap the storage adapter (`AshCache.Store.Adapter` behaviour — Cachex,
   ProcessLocal, Noop ship in-tree; Redis would be a new adapter):
   `config :ash_cache, adapter: MyAdapter` or per-process
   `Process.put(:ash_cache_adapter, MyAdapter)`.

## Safety properties worth knowing

- **Actor and tenant are always part of the key.** A cache hit bypasses the
  data layer, so filter-based policies are not re-applied on hits; keying by
  actor means a hit can only serve what that same actor already read through
  full authorization. What carries the rest of that guarantee is the key's
  `filter`: the policy authorizer has already folded its filter checks into
  `query.filter` by the time the cache hook runs, so a read taken with
  `authorize?: false` on an actor's behalf keys differently from that same
  actor's authorized read and cannot answer it. Simple (non-filter) checks
  need no such protection — they forbid the read outright, and a forbidden
  read caches nothing. Regression-tested both ways.
- **The full query shape is part of the key.** `Ash.get/2`, ad-hoc filters,
  limits and sorts all produce distinct entries — no cross-query collisions.
- **Failed writes touch nothing** (regression-tested).

## Status

`0.1.0`, extracted from the application it was written in, where it caches
two production resources. Three limits are deliberate in this version:

- **No per-key eviction.** With auto-derived keys a write cannot know every
  query shape that cached its resource, so invalidation is per-resource.
- **Loaded relationships go stale.** `load` is part of the key, so a cached
  entry can carry loaded relationships — but generations are per-resource, and
  a write to the related resource bumps its own counter, not the parent's. The
  parent entry keeps serving the old associations until its TTL expires. Keep
  `load` off cached reads, or treat the TTL as the staleness window you accept.
- **Writes cost more.** Every write bumps a generation counter. One
  write-heavy suite in the host app roughly doubled in runtime when its
  resource was cached — measure before caching a write-heavy resource.
