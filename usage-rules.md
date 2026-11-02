# Rules for working with AshCache

AshCache adds declarative read-through caching to Ash resources. Read these
rules before writing code that uses it. Prefer the defaults; add options only
when a requirement demands them.

## Setup

- Add `{:ash_cache, "~> 0.1"}` to deps.
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

- `ttl` (milliseconds) is required on every `read`; there is no
  block-level `ttl` and no way to cache all reads at once. Unlisted reads are
  never cached. Every name must be a read action on the resource, listed once, or
  compilation fails. A `cache` block with no `read` fails too.
- Options on `read`: `cache_empty?: true` caches `[]` and `nil` results (off
  by default); `adapter_options: [...]` is passed verbatim to the adapter's
  `put/4`.
- Options on the block: `store :name` gives the resource its own Cachex store
  (default `:ash_cache`).
- `warm :read_action, args: [arg: :attribute], actor: {Mod, :fun, []}`
  re-runs a cached read after each create/update with arguments taken from
  the written record. The entry is cached for that actor only (no actor by
  default) and for the written record's tenant, so `warm` only helps reads
  normally called the same way. Do not use it for per-user reads. Each
  `warm` costs the writer one extra read.
- Every successful create/update/destroy clears all cached reads of the
  resource, after commit.
- Cache only reads that are hot and tolerate staleness up to their `ttl`.
  Choose `ttl` per read: long for content that rarely changes, short for
  results that change without a write (time-based filters, aggregates over
  other resources, data written outside Ash).

## Rules

- The cache key is built per actor and tenant, however they are passed
  (code interface, `Ash.Query.for_read/4` or `Ash.read/2`).
- Do not cache reads that `load` related data unless a short `ttl` is
  acceptable. A write to the related resource does not clear the parent's
  entry.
- Do not cache values that must be exact at the moment of use: stock counts
  at checkout, balances, permissions checked for a payment.
- The default store is in memory per node. On several nodes a write clears
  the cache only on the node that made it; others serve old entries until
  `ttl`.
- Do not cache a write-heavy resource without measuring: every write also
  writes a new version value to the store.
- Do not write cache keys or invalidation by hand. Both are automatic.
- To skip the cache for one query, set `context: %{ash_cache: :bypass}`.
  Pass it to `Ash.Query.for_read/4` or `Ash.read/2`, or call
  `Ash.Query.set_context/2` before you run the query.
- To invalidate a resource at runtime (e.g. after a raw SQL import):
  `AshCache.invalidate(Resource)`.
- To wipe a whole store (all resources in it): `AshCache.clear_store(:name)`.
- To disable caching in one process (tests, scripts):
  `Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)`.
- A custom store implements `AshCache.Store.Adapter` (`get/2`, `put/4`,
  `del/2`, `clear/1`; a miss is `{:ok, nil}`) and is selected with
  `config :ash_cache, adapter: MyAdapter`.

## Telemetry and tests

- Events: `[:ash_cache, :read, :hit]`, `[:ash_cache, :read, :miss]`
  (metadata `:resource`, `:action`, `:store`; a miss also has `:error`) and
  `[:ash_cache, :invalidate]` (`:resource`, `:store`). Bypassed and uncached
  reads emit nothing.
- In tests, call `AshCache.Testing.capture_events()` in `setup`, then
  `assert_received {:ash_cache, :hit, %{action: :get_by_sku}}` (kinds:
  `:hit`, `:miss`, `:invalidate`). Safe with `async: true`. It only delivers
  events from the test process and Tasks it starts.
- With `ProcessLocal`, each process has its own cache: a Task or GenServer
  does not share the test's cache, and the test's writes do not clear it.
