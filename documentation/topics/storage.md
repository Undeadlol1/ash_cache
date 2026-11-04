# Storage

AshCache keeps cached results in a **store**. This guide covers the stores
that ship with the package, how to give a resource its own store, and how
to write an adapter for other storage.

## Built-in adapters

| Adapter | What it does | Use it for |
|---|---|---|
| `AshCache.Store.Adapters.Cachex` | Keeps entries in memory with [Cachex](https://hexdocs.pm/cachex). This is the default. Add `{:cachex, "~> 3.6"}` to your deps to use it. | Production on one server |
| `AshCache.Store.Adapters.Nebulex` | Keeps entries in your own [Nebulex](https://hexdocs.pm/nebulex) cache. | Several servers (experimental) |
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

## Running on several servers (experimental)

> #### Experimental {: .warning}
>
> Multi-server support was written with AI help and has not been tried on
> real servers. Its tests run three Elixir nodes on one computer. Don't
> rely on it in production until you have tested it in your own setup, and
> please [report what you find](https://github.com/Undeadlol1/ash_cache/issues).

The default Cachex store keeps each server's cache in that server's memory.
On several servers, a write clears the cache only on the server that made
it, and the others serve old results until `ttl` runs out.

The `AshCache.Store.Adapters.Nebulex` adapter is meant to share one cache
between servers through a [Nebulex](https://hexdocs.pm/nebulex) cache that
you set up yourself:

1. Add `{:nebulex, "~> 3.1"}` and a Nebulex adapter to your deps.
2. Define a Nebulex cache module, for example `MyApp.Cache`, and start it
   in your supervision tree instead of `AshCache.Supervisor`.
3. Set `config :ash_cache, adapter: AshCache.Store.Adapters.Nebulex`.
4. Set `store MyApp.Cache` in the `cache` block of every cached resource.

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
