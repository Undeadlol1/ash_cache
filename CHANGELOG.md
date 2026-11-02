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
- `action :name, ttl: ...` caches a generic action, such as a call to
  another service. On a hit its `run` is not called. Policies are still
  checked. Keys are built from the action, its arguments, the actor and the
  tenant; writes and `AshCache.invalidate/1` clear these entries too. An
  action with no return type, or whose `run` is a Reactor, fails to
  compile. Telemetry: `[:ash_cache, :action, :hit]` and
  `[:ash_cache, :action, :miss]`.
- `refresh` re-runs a cached read after each create or update, so the new
  value is cached before anyone asks for it.
- Version-based invalidation: a successful write bumps the resource's
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
