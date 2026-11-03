# Storage

AshCache keeps cached results in a **store**. This guide covers the stores
that ship with the package, how to give a resource its own store, and how
to write an adapter for other storage.

## Built-in adapters

| Adapter | What it does | Use it for |
|---|---|---|
| `AshCache.Store.Adapters.Cachex` | Keeps entries in memory with [Cachex](https://hexdocs.pm/cachex). This is the default. Add `{:cachex, "~> 3.6"}` to your deps to use it. | Production on one server |
| `AshCache.Store.Adapters.Nebulex` | Keeps entries in your own [Nebulex](https://hexdocs.pm/nebulex) cache. | Production on several servers |
| `AshCache.Store.Adapters.ProcessLocal` | Gives each process its own private cache. | Tests |
| `AshCache.Store.Adapters.Noop` | Saves nothing. Every read goes to the database. | Turning caching off |

Choose one for the whole application in config:

```elixir
config :ash_cache, adapter: AshCache.Store.Adapters.Noop
```

Or for the current process only:

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

## Running on several servers

> #### Not tested on real servers yet {: .warning}
>
> Running AshCache on several servers has not been tried on real
> hardware. The tests start three Elixir nodes on one computer, all
> joined to one shared Nebulex cache. They check that an entry saved on
> one node is found on the others, and that clearing the cache on one node
> clears it on all of them. They call the store directly; they don't run
> Ash reads and writes across nodes. Nothing has been run on separate
> machines, against a real Redis server, or with the replicated, coherent
> or multilevel adapters.
> Test it in your own setup before relying on it, and please
> [report what you find](https://github.com/Undeadlol1/ash_cache/issues).

The Cachex adapter keeps each server's cache in that server's memory. On
several servers, a write clears the cache only on the server that made it,
and the others serve old results until their `ttl` runs out.

To share one cache between servers, use the Nebulex adapter. You pick and
configure a Nebulex cache; Nebulex connects the servers. AshCache does not
manage servers itself.

1. Add Nebulex and the Nebulex adapter you want to your deps. For Redis:

   ```elixir
   {:nebulex, "~> 3.1"},
   {:nebulex_redis_adapter, "~> 3.1"}
   ```

2. Define the cache and configure it:

   ```elixir
   defmodule MyApp.Cache do
     use Nebulex.Cache, otp_app: :my_app, adapter: Nebulex.Adapters.Redis
   end
   ```

   ```elixir
   # Give AshCache a Redis database of its own: AshCache.clear_store/1
   # empties the whole database (Redis FLUSHDB).
   config :my_app, MyApp.Cache, conn_opts: [host: "redis.internal", database: 3]

   config :ash_cache, adapter: AshCache.Store.Adapters.Nebulex
   ```

3. Start `MyApp.Cache` in your supervision tree **instead of**
   `AshCache.Supervisor`, which only starts Cachex stores.

4. Name the cache as the `store` of every cached resource. The store name
   is the cache module:

   ```elixir
   cache do
     store MyApp.Cache
     read :read, ttl: :timer.minutes(10)
   end
   ```

Which Nebulex adapter to use:

- **Redis** (`nebulex_redis_adapter`) or **partitioned**
  (`Nebulex.Adapters.Partitioned` in `nebulex_distributed`): every server
  reads the same copy of each entry, so a write on one server clears the
  cache for all of them.
- **Replicated** (`Nebulex.Adapters.Replicated`): every server holds a copy
  and writes go to all of them.
- **Coherent**, or **multilevel** with a local level in front: each server
  keeps its own copy. Another server's write reaches it a little later
  (coherent), or only when that copy expires (multilevel's local level).
  Until then that server can serve old results. Avoid these for AshCache, or keep `ttl` short.
- **Local** (`nebulex_local`): one server only, like Cachex.

### A lost entry never brings back old data

Each resource has a version value in the store, and every key contains it.
Stores lose entries: Redis evicts keys when memory is full, a server leaves
a partitioned cache and takes its entries with it, a cache restarts. When
the version value is gone, AshCache picks a brand-new one, so every read of
that resource misses once and goes to the database. A version value is
random and used once, so no old key can come back. The test suite checks
this with a three-server partitioned cache, including stopping the server
that holds the value.

One case remains: if the store accepts reads but refuses both to save the
new version value and to delete the old one after a write, reads can keep
returning results cached before that write until their `ttl` runs out.
AshCache logs a warning when this happens.

## Give a resource its own store

All resources share the `:ash_cache` store by default. Set `store` to give
a resource a store of its own:

```elixir
cache do
  store :products_cache
  read :read, ttl: :timer.minutes(10)
end
```

With the default Cachex adapter, `AshCache.Supervisor` starts every store
your resources name. To empty one
store without touching the others:

```elixir
AshCache.clear_store(:products_cache)
```

## Write your own adapter

An adapter is a module that implements `AshCache.Store.Adapter`: `get/2`,
`put/4`, `delete/2` and `clear/1`. Start from the built-in
[Cachex adapter](https://github.com/Undeadlol1/ash_cache/blob/main/lib/ash_cache/store/adapters/cachex.ex),
which is about thirty lines.

Your adapter has to follow these rules:

- **Keys are Elixir terms**, not strings. They contain tuples, maps and
  structs. A store such as Redis needs them turned into strings first.
- **A missing key returns `{:ok, nil}`**, not an error.
- **`put/4` gets a `:ttl`** in milliseconds, or `:infinity`.
- **`put/4` can get `never_evict: true`.** Keep that entry when making room if you
  can. AshCache uses it for the version values that make clearing work.
  Losing one is safe but makes every cached read of that resource miss once.
- **`clear/1` removes only the given store's entries**, not everything in
  the backend.

Set it as the adapter:

```elixir
config :ash_cache, adapter: MyApp.MyCacheAdapter
```

### Pass options to your adapter

Anything a `read` sets in `store_options` is passed to your `put/4`
along with `:ttl`:

```elixir
cache do
  read :read, ttl: :timer.minutes(10), store_options: [prefix: "products"]
end
```

### Test your adapter

Copy the package's contract test, `test/support/store_contract.ex` in the
repository. It runs the same `get`, `put`, `delete`, `clear` and expiry checks
against every built-in adapter.
