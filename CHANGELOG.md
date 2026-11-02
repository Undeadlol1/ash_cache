# Changelog

## 0.1.0 — unreleased

First packaged release. Extracted from the application it was written in,
where it caches two production resources.

- `AshCache.Resource` extension. Each read to cache is listed on its own
  with an optional lifetime: `read :get_by_sku, ttl: :timer.hours(1)`.
  Reads without one use the block's `ttl`, which is 5 minutes unless set.
  `:infinity` is allowed, but only when written out.
  `cache_empty?` and `store_options` are set per read too. Reads that are
  not listed are never cached. Keys are built from the action, the whole
  query, the actor and the tenant.
- `refresh` re-runs a cached read after each create or update, so the new
  value is cached before anyone asks for it.
- Version-based invalidation: a successful write bumps the resource's
  counter in `after_transaction`, so a rolled-back write cannot leave stale
  entries behind and old entries become unreachable in O(1).
- Telemetry events `[:ash_cache, :read, :hit]`, `[:ash_cache, :read, :miss]`
  and `[:ash_cache, :invalidate]`.
- `AshCache.Testing.capture_events/0` sends a test the cache events its own
  code caused, so cache behaviour can be checked in `async: true` tests.
- Cachex is an optional dependency. Add it to your deps to use the default
  store. Without it, AshCache fails at startup with a message saying so,
  unless you set another adapter.
- Store adapters: `Cachex` (default), `ProcessLocal` (per-process isolation
  for async tests) and `Noop`, behind `AshCache.Store.Adapter`.
- `AshCache.Store.Adapters.Nebulex` stores entries in the app's own Nebulex
  cache, so several servers can share one cache (Redis, partitioned,
  replicated). Nebulex is an optional dependency.
- A version value the store loses (eviction, restart, a server leaving a
  distributed cache) is replaced by a new random one, so it can never bring
  back entries cached before a write. A write whose new version value the
  store refuses deletes the old one instead, and logs a warning if the store
  refuses that too.
- `AshCache.Supervisor` starts one store per declared cache with no manual
  wiring beyond a single child spec.

Known limits, both deliberate in this version:

- No per-key eviction. With auto-derived keys a write cannot know every
  query shape that cached its resource, so invalidation is per-resource.
- Caching a write-heavy resource costs write throughput, because every write
  writes a new version value to the store. One write-heavy test suite in the host app
  roughly doubled in runtime when its resource was cached.
