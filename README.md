# AshCache

[![Hex.pm](https://img.shields.io/hexpm/v/ash_cache.svg)](https://hex.pm/packages/ash_cache)
[![HexDocs](https://img.shields.io/badge/hexdocs-ash__cache-blue.svg)](https://hexdocs.pm/ash_cache)
[![CI](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/ash_cache.svg)](https://github.com/Undeadlol1/ash_cache/blob/main/LICENSE)

A cache for [Ash](https://hexdocs.pm/ash) resources. Reads come back from
memory instead of the database, and the cache clears itself when the data
changes.

## What you get

- **You pick what is cached.** List the reads to cache in a `cache` block on
  the resource.
- **No manual clearing.** When a record is created, updated or deleted, the
  cache for that resource is cleared.
- **No data leaks between users.** Each user and each tenant has their own
  cached results.

## Installation

Add the package to `mix.exs`:

```elixir
def deps do
  [
    {:ash_cache, "~> 0.1"},
    {:cachex, "~> 3.6"}
  ]
end
```

Cachex is the default store. To use another store, see the Storage guide.

Add the supervisor to your application. It starts the cache stores:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {AshCache.Supervisor, otp_app: :my_app}
]
```

## Usage

Add the extension to a resource and list each read to cache. `ttl` is how
long its results are kept, in milliseconds:

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_sku, ttl: :timer.hours(1)
    read :featured, ttl: :timer.minutes(1)
  end
end
```

`get_by_sku` and `featured` now come from the cache. Other reads go to the
database as before. The cache clears when a product is created, updated or
deleted.

`ttl` is optional. A read without one keeps its results for 5 minutes. To
change that for every read of the resource, set `ttl` on the block:

```elixir
cache do
  ttl :timer.hours(1)

  read :get_by_sku
  read :featured, ttl: :timer.minutes(1)
end
```

Here `get_by_sku` keeps results for an hour and `featured` for a minute.

`ttl: :infinity` keeps results until the resource changes. Use it only
for data that is rarely written: a write doesn't delete old results from
memory, it only stops them being used, and they stay in memory until
their `ttl` runs out.

The [Examples](documentation/topics/examples.md) page shows the `cache`
block for common app features.

## When cached results are thrown away

A cached result is thrown away in three cases:

1. **The resource is changed through Ash.** Creating, updating or deleting
   any product throws away every cached product read, right away.
2. **The `ttl` runs out**, even if nothing changed.
3. **You call `AshCache.invalidate(MyApp.Shop.Product)`.** Use this when the
   data changed without Ash, for example after an import.

Changes to other resources don't count. If a cached post read includes the
post's comments, adding a comment doesn't throw it away. The comments
update when the `ttl` runs out, or sooner if you call
`AshCache.invalidate(MyApp.Blog.Post)` after creating a comment.

## Learn more

- [Examples](documentation/topics/examples.md): the `cache` block for common
  app features, and when not to cache.
- [Storage](documentation/topics/storage.md): the built-in stores, running
  on several nodes, and writing your own adapter.
- [How to test with AshCache](documentation/topics/testing.md): check that a
  read is cached and that a write clears it, keep parallel tests apart.
- [How AshCache works](documentation/topics/how-it-works.md): what goes in
  a cache key, how clearing works, and the limits.
- [DSL reference](documentation/dsls/DSL-AshCache.Resource.md): every
  option in the `cache` block.

## Limits

- **The cache clears per resource, not per record.** Any write to a
  resource clears every cached read of that resource.
- **Related records can go stale.** A cached read that loads related
  records keeps the old related records until the entry expires. Keep
  `load` off cached reads, or choose a short `ttl`.
- **The default store is per server.** On several servers, a write clears
  the cache only on the server that made it. To share one cache, use the
  Nebulex adapter with Redis or a partitioned cache. See
  [Storage](documentation/topics/storage.md#running-on-several-servers).
- **No protection when a popular entry runs out.** Every request that
  arrives before the read is cached again goes to the database. Choose a
  `ttl` your database can handle that burst for.
- **Writes get a little slower.** Each write has to clear the cache.
  Measure before caching a resource that is written to constantly.

## For AI assistants

<details>
<summary>Instructions for coding agents (Claude Code, Cursor, Copilot, ...)</summary>
<p>
The file for agents is
<a href="https://github.com/Undeadlol1/ash_cache/blob/main/usage-rules.md"><code>usage-rules.md</code></a>.
It ships inside the package, so after <code>mix deps.get</code> it is at
<code>deps/ash_cache/usage-rules.md</code>. Point your agent at that file.
If your project uses the
<a href="https://hexdocs.pm/usage_rules"><code>usage_rules</code></a>
package, add <code>:ash_cache</code> to its list instead.
</p>
</details>

## License

MIT. See [LICENSE](https://github.com/Undeadlol1/ash_cache/blob/main/LICENSE).
