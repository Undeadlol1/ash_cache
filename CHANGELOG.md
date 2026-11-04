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
- `clear_when_changed [MyApp.Blog.Comment]` throws away a resource's cached
  reads and generic actions when a listed resource is created, updated or
  deleted through Ash. The listed resource needs the `AshCache.Resource`
  extension, but no `cache` block: a resource may now use the extension
  without caching anything.
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
- Experimental: `AshCache.Store.Adapters.Nebulex` stores entries in the
  app's own Nebulex cache, so several servers can share one cache. Not yet
  tested on real servers. Nebulex is an optional dependency.
- A version value the store loses (eviction, restart, a server leaving a
  distributed cache) is replaced by a new random one, so it can never bring
  back entries cached before a write. A write whose new version value the
  store refuses deletes the old one instead, and logs a warning if the store
  refuses that too.
- Requests that miss the same cached read at the same time on one server
  share a single database read instead of each running it. If that read
  fails, another waiting request runs it; after `rebuild_timeout` (5 seconds
  by default) the others stop waiting and read for themselves. Cached
  generic actions do the same with their `run` call.
- A read whose rows are computed from another resource (an aggregate, a
  calculation over one, or a filter, sort or policy that reaches another
  resource) is cached only when every resource it reaches is the resource
  itself or in `clear_when_changed`; otherwise it goes to the data layer
  every time. Related records loaded with `load` are read fresh on every
  read and need nothing. A per-owner policy (`relates_to_actor_via` over a
  `belongs_to`) compares only the row's own foreign key and needs nothing
  either. A cache hit no longer hangs when the read loads an aggregate.
- `AshCache.Supervisor` starts one store per declared cache with no manual
  wiring beyond a single child spec.

Known limits, both deliberate in this version:

- No per-key eviction. With auto-derived keys a write cannot know every
  query shape that cached its resource, so invalidation is per-resource.
- Caching a write-heavy resource costs write throughput, because every write
  writes a new version value to the store. One write-heavy test suite in the host app
  roughly doubled in runtime when its resource was cached.
