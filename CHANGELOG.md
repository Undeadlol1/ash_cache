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
<<<<<<< HEAD
- `clear_when_changed [MyApp.Blog.Comment]` throws away a resource's cached
  reads when a listed resource is created, updated or deleted through Ash.
  The listed resource needs the `AshCache.Resource` extension, but no
  `cache` block: a resource may now use the extension without caching any
  read.
- Generation-based invalidation: a successful write bumps the resource's
=======
- Version-based invalidation: a successful write bumps the resource's
>>>>>>> origin/per-read-ttl
  counter in `after_transaction`, so a rolled-back write cannot leave stale
  entries behind and old entries become unreachable in O(1).
- Telemetry events `[:ash_cache, :read, :hit]`, `[:ash_cache, :read, :miss]`
  and `[:ash_cache, :invalidate]`.
- `AshCache.Testing.capture_events/0` sends a test the cache events its own
  code caused, so cache behaviour can be checked in `async: true` tests.
- Store adapters: `Cachex` (default), `ProcessLocal` (per-process isolation
  for async tests) and `Noop`, behind `AshCache.Store.Adapter`.
- `AshCache.Supervisor` starts one store per declared cache with no manual
  wiring beyond a single child spec.

Known limits, both deliberate in this version:

- No per-key eviction. With auto-derived keys a write cannot know every
  query shape that cached its resource, so invalidation is per-resource.
- Caching a write-heavy resource costs write throughput, because every write
  bumps a version counter. One write-heavy test suite in the host app
  roughly doubled in runtime when its resource was cached.
