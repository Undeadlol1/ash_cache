# Changelog

## 0.1.0 — unreleased

First packaged release. Extracted from the application it was written in,
where it caches two production resources.

- `AshCache.Resource` extension: `cache do reads [...] end` caches the listed
  read actions, keyed by action, arguments, query shape, actor and tenant.
- Generation-based invalidation: a successful write bumps the resource's
  counter in `after_transaction`, so a rolled-back write cannot leave stale
  entries behind and old entries become unreachable in O(1).
- Store adapters: `Cachex` (default), `ProcessLocal` (per-process isolation
  for async tests) and `Noop`, behind `AshCache.Store.Adapter`.
- `AshCache.Supervisor` starts one store per declared cache with no manual
  wiring beyond a single child spec.

Known limits, both deliberate in this version:

- No per-key eviction. With auto-derived keys a write cannot know every
  query shape that cached its resource, so invalidation is per-resource.
- Caching a write-heavy resource costs write throughput, because every write
  bumps a generation counter. One write-heavy test suite in the host app
  roughly doubled in runtime when its resource was cached.
