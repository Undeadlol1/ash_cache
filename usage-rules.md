# Rules for working with AshCache

AshCache adds declarative read-through caching to Ash resources. Read these
rules before writing code that uses it. Prefer the defaults; add options only
when a requirement demands them.

## Setup

- Add `{:ash_cache, "~> 0.2"}` and `{:cachex, "~> 3.6"}` to deps. Cachex is
  the default store and is optional: skip it only if you set another adapter.
- Add `{AshCache.Supervisor, otp_app: :my_app}` to the application's
  supervision tree exactly once, after the repo. It starts one Cachex store
  per distinct `store` name declared across all domains in
  `config :my_app, ash_domains`.
- No application config is required. For isolated `async: true` tests, set in
  `config/test.exs` `config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal`.
- Ash needs a SAT solver (`:picosat_elixir` or `:simple_sat`) to evaluate
  policies. That is the application's dependency, not AshCache's.

## Caching a resource

- Add `extensions: [AshCache.Resource]` to `use Ash.Resource` and a `cache`
  block with one `read` per read action to cache:

  ```elixir
  cache do
    read :get_by_sku, ttl: :timer.hours(1)
    read :featured, ttl: :timer.minutes(1), cache_empty?: true
  end
  ```

- `ttl` (milliseconds or `:infinity`) is optional on each `read`. Without it
  the read uses the block's `ttl`, which defaults to 5 minutes
  (`cache do ttl :timer.hours(1) ... end` changes it for the resource).
  `:infinity` is never the default: old entries stay in memory until their
  `ttl` runs out, so only use it for data that is written rarely. There is
  no way to cache all reads at once. Unlisted reads are never cached. Every name must be a read action on the resource, listed once, or
  compilation fails.
- Options on `read`: `cache_empty?: true` caches `[]` and `nil` results (off
  by default); `store_options: [...]` is passed verbatim to the adapter's
  `put/4`.
- `action :name, ttl: ...` caches a generic action the same way, keyed by
  its arguments, actor and tenant; on a hit its `run` is not called. It
  takes the same options as `read`, and the same `ttl` default. Errors and
  `nil` are never cached. The action must have a return type and its `run`
  must not be a Reactor, or compilation fails. Policies are still checked
  on every call.
- `calculation :name, ttl: ...` caches a module calculation
  (`Ash.Resource.Calculation`) per record, keyed by its arguments, actor,
  tenant and every attribute and `load/3` field of the record. Writes do
  not clear it; a changed record gets a new key. Use it only for a
  calculation that depends on the record alone: one that reads an API or
  the clock serves old answers until `ttl`. Expression calculations fail
  compilation; they need no entry. Events:
  `[:ash_cache, :calculation, :hit | :miss]`.
- Options on the block: `store :name` gives the resource its own store
  (default `:ash_cache`); `ttl` sets the lifetime for reads without their own.
  With the Nebulex adapter the store is the Nebulex cache module:
  `store MyApp.Cache`.
- `recache_after_write :read_action` caches a cached read again after each
  create/update (not destroy). Each read argument is taken from the written
  record's attribute of the same name; `arguments: [arg: :attribute]` maps
  only the ones whose names differ. A required argument with no source fails
  compilation. `actor: {Mod, :fun, []}` sets the actor; the entry is cached
  for that actor only (no actor by default) and for the written record's
  tenant, so it only helps reads normally called the same way. Do not use it
  for per-user reads. Each one costs the writer one extra read.
- Every successful create/update/destroy clears all cached reads and
  generic actions of the resource, after commit.
- `clear_when_changed [MyApp.Blog.Comment]` on the block also clears the
  resource's cached reads and generic actions when a listed resource is
  created, updated or destroyed through Ash (single or bulk), after commit.
  Each listed resource must use `extensions: [AshCache.Resource]`; it needs
  no `cache` block. Listing a module that is not such a resource fails
  compilation. It is not passed along: if Post lists Comment and Comment
  lists Author, an Author write does not clear Post. List Author on Post too.
- Identical misses running at the same time on one server share one data
  layer read or one generic action `run` (keyed on the full cache key, so
  never across actors or tenants). Do not add your own locking around cached
  reads or actions. Waiters give up after
  `config :ash_cache, rebuild_timeout: ms` (default 5000) and run for
  themselves.
- Cache only reads that are hot and tolerate staleness up to their `ttl`.
  Choose `ttl` per read: long for content that rarely changes, short for
  results that change without a write (time-based filters, data written
  outside Ash).

## Rules

- The cache key is built per actor and tenant, however they are passed
  (code interface, `Ash.Query.for_read/4` or `Ash.read/2`).
- Related records a cached read `load`s are read fresh on every request;
  they need nothing. A read whose rows are computed from another resource
  (an aggregate, a calculation over one, or a filter, sort or policy that
  reaches another resource) is cached only when every resource it reaches
  is in `clear_when_changed`, including a `many_to_many` join resource.
  Otherwise it always goes to the data layer. Do not shorten `ttl` for this.
- Do not cache values that must be exact at the moment of use: stock counts
  at checkout, balances, permissions checked for a payment.
- The default store is in memory per node. On several nodes a write clears
  the cache only on the node that made it; others serve old entries until
  `ttl`. Sharing one cache is experimental (not tested on real servers);
  only set it up if the user asks. To share one cache, set
  `config :ash_cache, adapter: AshCache.Store.Adapters.Nebulex`, start your
  own Nebulex cache (Redis, partitioned or replicated) instead of
  `AshCache.Supervisor`, and set `store MyApp.Cache` on every cached
  resource. Do not use a coherent or multilevel-with-local cache: other
  servers can serve old entries. With Redis, give AshCache its own database:
  `AshCache.clear_store/1` runs FLUSHDB.
- Do not cache a write-heavy resource without measuring: every write also
  writes a new version value to the store.
- Do not write cache keys or invalidation by hand. Both are automatic.
- To skip the cache for one query, set `context: %{ash_cache: :bypass}`.
  Pass it to `Ash.Query.for_read/4` or `Ash.read/2`, or call
  `Ash.Query.set_context/2` before you run the query. For a generic action,
  pass it to `Ash.ActionInput.for_action/4` or call
  `Ash.ActionInput.set_context/2`.
- To invalidate a resource at runtime (e.g. after a raw SQL import):
  `AshCache.invalidate(Resource)`.
- To wipe a whole store (all resources in it): `AshCache.clear_store(:name)`.
- To disable caching in one process (tests, scripts):
  `Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)`.
- A custom store implements `AshCache.Store.Adapter` (`get/2`, `put/4`,
  `delete/2`, `clear/1`; a miss is `{:ok, nil}`) and is selected with
  `config :ash_cache, adapter: MyAdapter`.

## Telemetry and tests

- Events: `[:ash_cache, :read, :hit]`, `[:ash_cache, :read, :miss]`
  (metadata `:resource`, `:action`, `:store`; a miss also has `:error`) and
  `[:ash_cache, :invalidate]` (`:resource`, `:store`). Generic actions send
  `[:ash_cache, :action, :hit]` and `[:ash_cache, :action, :miss]` with the
  same metadata. Bypassed and uncached
  reads emit nothing.
- In tests, call `AshCache.Testing.capture_events()` in `setup`, then
  `assert_received {:ash_cache, :hit, %{action: :get_by_sku}}` (kinds:
  `:hit`, `:miss`, `:invalidate`). Safe with `async: true`. It only delivers
  events from the test process and Tasks it starts.
- With `ProcessLocal`, each process has its own cache: a Task or GenServer
  does not share the test's cache, and the test's writes do not clear it.
