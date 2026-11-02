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
- No application config is required. For isolated `async: true` tests, set in `config/test.exs`
  `config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal`.
- Ash needs a SAT solver (`:picosat_elixir` or `:simple_sat`) to evaluate
  policies. That is the application's dependency, not AshCache's.

## Caching a resource

- Add `extensions: [AshCache.Resource]` to `use Ash.Resource` and an empty
  `cache do end` block. That is the complete, recommended configuration.
- Defaults: every read action cached, TTL one hour, store `:ash_cache`,
  empty results not cached, every create/update/destroy invalidates the
  resource after commit.
- Options inside `cache do`:
  - `ttl` milliseconds, e.g. `ttl :timer.minutes(5)`.
  - `store :name` to give the resource its own Cachex store.
  - `reads [:action, ...]` to cache only those read actions. Every name
    must be a read action on the resource; the verifier rejects anything
    else at compile time.
  - `cache_empty? true` to cache `[]` and `nil` results.
  - `adapter_options [...]` passed verbatim to the adapter's `put/4`.
  - `warm :read_action, args: [arg: :attribute], actor: {Mod, :fun, []}`
    re-runs that read after each create/update with arguments taken from
    the written record. Each `warm` costs the writer one extra read.

## Rules

- Do not cache a resource whose cached reads use `load`. Generations are
  per resource, so a write to the related resource does not invalidate the
  parent's entry. If `load` is unavoidable, keep the TTL short.
- Do not cache a write-heavy resource without measuring: every write bumps
  a generation counter in the store.
- Do not write cache keys or invalidation by hand. Keys are derived from the
  action, full query shape, actor and tenant; invalidation happens in
  `after_transaction`. Both are automatic.
- Do not clear the cache in `after_action`; a rolled-back write would leave
  stale entries. AshCache already uses `after_transaction`.
- To skip the cache for one query:
  `Ash.Query.set_context(query, %{ash_cache: :bypass})`.
- To invalidate a resource at runtime: `AshCache.invalidate(Resource)`.
- To wipe a whole store (all resources in it): `AshCache.clear_store(:name)`.
- To disable caching in one process (tests, scripts):
  `Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)`.
- A custom store implements `AshCache.Store.Adapter` (`get/2`, `put/4`,
  `del/2`, `clear/1`; a miss is `{:ok, nil}`) and is selected with
  `config :ash_cache, adapter: MyAdapter`.
