# Rules and limits

What AshCache clears, saves, keys on, configures and reports, and where it
stops. Every option of the `cache` block is in the
[DSL reference](../dsls/DSL-AshCache.Resource.md).

## What clears the cache

A cached result is thrown away when:

1. **The resource is changed through Ash.** Creating, updating or deleting
   any product throws away every cached product read and generic action,
   right away.
2. **A resource listed in `clear_when_changed` is changed through Ash.**
3. **Its `ttl` runs out**, even if nothing changed.
4. **It is cleared by hand** with `AshCache.invalidate/1` or
   `AshCache.clear_store/1`.

Nothing else clears it. A change made without Ash, such as raw SQL, an
import script or another service writing to the same table, shows up only
when `ttl` runs out.

Any write to a resource clears every cached read of that resource, not
only the entries that contain the changed record. Updating one product
clears the cached lookup of every product.

The cache is cleared after the database transaction commits. A write that
fails or is rolled back leaves the cache as it was.

Calculation entries are not cleared by writes or by
`AshCache.invalidate/1`, and there is no `clear_when_changed` for them.

How to clear: [When the cache clears](clearing.md). Why it works this way:
[How AshCache works](how-it-works.md#on-a-write).

## What is saved

- `ttl` is in milliseconds. A read without one keeps its results for 5
  minutes, or for the `cache` block's `ttl` if there is one. A `ttl` on a
  read or action overrides the block's.
- **Reads:** a result is saved if it has at least one record. An empty
  result is saved only with `cache_empty?: true` on the `read`.
- **Generic actions:** errors and `nil` are never saved. `[]` is saved
  only with `cache_empty?: true`. The action must have a return type. An
  action whose `run` is a Reactor cannot be cached; call the Reactor from a
  `run` function instead. A read action with `manual` is cached with `read`,
  not `action`. Ash checks the resource's policies on every call, also when
  the answer comes from the cache.
- **Calculations:** `nil` and `[]` are saved. An error is never saved. Only
  module calculations can be cached; naming an expression calculation in
  the `cache` block is a compile error.

## What is in a key

A key is built from:

1. the resource,
2. the resource's current **version value**, and the version value of each
   resource listed in `clear_when_changed`,
3. the name of the action,
4. for a read, everything about the query that affects its result:
   arguments, filter, sort, limit, offset, page, distinct, select, load,
   calculations and aggregates.
   For a generic action, its arguments,
5. the current actor and tenant.

The key of a cached calculation holds the calculation's arguments, the
actor, the tenant, every attribute of the record, and the value of every
field the calculation loads (the fields its `load/3` names).

## Settings

| Setting | Meaning |
|---|---|
| `config :ash_cache, rebuild_timeout: ms` | How long requests that miss at the same moment wait for the first one before each asking the database themselves. Default 5 seconds. |
| `config :ash_cache, adapter: module` | The store adapter for the whole application. See [Storage](storage.md#built-in-adapters). |
| `Process.put(:ash_cache_adapter, module)` | The store adapter for the current process only. |
| `context: %{ash_cache: :bypass}` | Skips the cache for one query, action input or load. See [A report that must be exact](examples.md#a-report-that-must-be-exact). |

```elixir
config :ash_cache, rebuild_timeout: :timer.seconds(10)
```

## Telemetry events

| Event | Sent when |
|---|---|
| `[:ash_cache, :read, :hit]` | A cached read's result came from the cache. |
| `[:ash_cache, :read, :miss]` | A cached read went to the database. |
| `[:ash_cache, :action, :hit]` | A cached generic action's result came from the cache. |
| `[:ash_cache, :action, :miss]` | A cached generic action ran. |
| `[:ash_cache, :calculation, :hit]` | A cached calculation's result came from the cache, for every record. |
| `[:ash_cache, :calculation, :miss]` | A cached calculation ran, for every record. |
| `[:ash_cache, :invalidate]` | A clear. |

Attach a handler to count hit rates in production. The events and their
metadata are listed in `AshCache`; for tests, use `AshCache.Testing` (see
[How to test with AshCache](testing.md)).

## Limits

- **The cache clears per resource, not per record.** Any write to a
  resource clears every cached read and generic action of that resource.
- **Values computed from another resource need it listed.** A cached entry
  holds the rows and what the data layer computed with them: aggregates,
  calculations, and the effect of a filter, sort or policy. It does not hold
  related records: Ash loads those after the rows on every read, so they
  are always fresh. When the computed part reaches another resource,
  AshCache stores the result only if every resource on the way is the
  resource itself or in `clear_when_changed` (a `many_to_many` counts its
  join resource too). Otherwise the read goes to the data layer every time.
  A value loaded under a name of its own (`Ash.Query.calculate/4`,
  `Ash.Query.aggregate/4`) cannot be traced, so it is never cached. See
  `AshCache.Dependencies`.
- **The default store is per server.** On several servers, a write clears
  the cache only on the server that made it. Sharing one cache between
  servers is experimental and not tested on real servers; see
  [Storage](storage.md#running-on-several-servers-experimental).
- **Cached calculations are not cleared by writes.** A changed record gets
  a new result at once, but a calculation that reads something outside the
  record (an API, the clock, the query's context) can serve an old answer
  until its `ttl` runs out.
- **Any attribute change recomputes a calculation.** Every attribute is in
  the key, also the ones the calculation does not use.
- **No sharing of simultaneous misses for calculations.** Reads and generic
  actions share one run on a server; calculations don't, so identical
  misses at the same moment each run the calculation.
- **`ttl: :infinity` holds memory.** A write doesn't delete old results,
  it only stops them being used. They stay in memory until their `ttl`
  runs out, so use `:infinity` only for data that is rarely written.
- **Writes get slower.** Every write stores a new value in the cache. In one
  write-heavy test suite, caching the resource roughly doubled the suite's
  runtime. Measure before caching a resource that is written to constantly.
