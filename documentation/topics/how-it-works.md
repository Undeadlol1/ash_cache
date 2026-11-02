# How It Works

AshCache hooks into two places in an Ash resource: a preparation on every
cached read action, and a change on every create, update and destroy. This
guide walks through both and then the escape hatches around them.

## The read path

Each cached read action gets a preparation
(`AshCache.Preparations.ReadThrough`). Before the data layer runs, it derives
a key from the query and looks it up in the store:

- **Hit**: the cached records are returned and the data layer is skipped.
- **Miss**: the read runs normally and, if it returned at least one record,
  the result is stored under that key with the resource's TTL.

Empty results are not cached by default, so a row that does not exist yet
cannot be "remembered" as missing. Set `cache_empty? true` to change that.

## The key

A key is a plain Erlang term built by `AshCache.Key` from:

1. the resource module,
2. the resource's current **generation** (see below),
3. the read action name,
4. the full query shape: arguments, `filter`, `sort`, `limit`, `offset`,
   `page`, `distinct`, `select` and `load`,
5. the **actor** and the **tenant**.

Because the full query is in the key, `Ash.get/2`, an ad-hoc filter, and a
paginated list each get their own entry. Because the actor is in the key, a
hit can only serve what that same actor already read through full
authorization. The policy authorizer folds its filter checks into
`query.filter` before the key is derived, so a read run with
`authorize?: false` keys differently from the same actor's authorized read and
can never answer it.

## Invalidation by generation

Every resource has a generation counter stored in the same store as its
entries (`AshCache.Generation`). The counter is part of every key.

A successful write bumps the counter (`AshCache.Changes.BumpGeneration`) in
the action's `after_transaction` hook, never in `after_action`. That ordering
matters: a write that rolls back never reaches `after_transaction`, so it
cannot leave stale entries behind.

After a bump, every key built with the old generation is simply never looked
up again. Old entries are not deleted one by one; they age out with their
TTL. Invalidation is therefore O(1) no matter how many query shapes were
cached.

This is also why invalidation is **per resource**: with keys derived from
arbitrary queries, a write cannot enumerate every entry it should remove, so
it removes all of them at once.

## Write-through warming

By default the first read after a write pays for a database round trip.
`warm` moves that cost onto the writer:

```elixir
cache do
  warm :get_by_sku, args: [sku: :sku], actor: {MyApp.SystemActor, :system, []}
end
```

After every successful create or update, AshCache re-runs the named read
action with arguments taken from the written record, so the fresh value is
cached before anyone asks for it. Warming executes the real read action, so
it shares key derivation and authorization with ordinary reads. It runs
synchronously in `after_transaction`, so each declaration costs the writer
one extra read. A warm that fails is logged and swallowed: the generation
bump already made the stale entry unreachable.

## Escape hatches

In increasing depth:

1. **Options in the block.** `ttl`, `store`, `reads`, `cache_empty?` and
   `adapter_options`. See the [DSL reference](../dsls/DSL-AshCache.Resource.md).
2. **Bypass one query.**
   `Ash.Query.set_context(query, %{ash_cache: :bypass})` reads straight from
   the data layer and stores nothing.
3. **Runtime helpers.** `AshCache.invalidate(resource)` bumps a resource's
   generation exactly like a write does. `AshCache.clear_store(store)` wipes a
   whole store, including other resources' entries.
4. **Swap the storage adapter.** Implement `AshCache.Store.Adapter` (four
   callbacks: `get`, `put`, `del`, `clear`) and point AshCache at it with
   `config :ash_cache, adapter: MyAdapter`, or per process with
   `Process.put(:ash_cache_adapter, MyAdapter)`. Three adapters ship in the
   package: `Cachex` (default), `ProcessLocal` (tests) and `Noop` (caching
   off).

## Deliberate limits

- **Loaded relationships go stale.** `load` is part of the key, so an entry
  can carry loaded relationships. Generations are per resource, though: a
  write to a related resource bumps its own counter, not the parent's, and
  the parent entry keeps serving the old associations until its TTL expires.
  Keep `load` off cached reads, or treat the TTL as the staleness window you
  accept.
- **Writes cost more.** Every write bumps a counter in the store. One
  write-heavy test suite roughly doubled in runtime after its resource was
  cached. Measure before caching a write-heavy resource.
- **No per-key eviction.** Covered above: a write clears the whole resource.
