# AshCache

[![Hex.pm](https://img.shields.io/hexpm/v/ash_cache.svg)](https://hex.pm/packages/ash_cache)
[![HexDocs](https://img.shields.io/badge/hexdocs-ash__cache-blue.svg)](https://hexdocs.pm/ash_cache)
[![CI](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/ash_cache.svg)](https://github.com/Undeadlol1/ash_cache/blob/main/LICENSE)

A cache for [Ash](https://hexdocs.pm/ash) resources. Reads come back from
memory instead of the database, and the cache clears itself when the data
changes.

## TL;DR

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_sku
  end
end
```

The first `get_by_sku` read goes to the database and its results are
saved. The next reads come from the cache, not the database. That's it.

## Features

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

Cachex is the default store. To use another store, see the [Storage](documentation/topics/storage.md) guide.

Add the supervisor to your application. It starts the cache stores:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {AshCache.Supervisor, otp_app: :my_app}
]
```

## Usage

### Set how long results are kept

`ttl` is in milliseconds. A read without one keeps its results for 5
minutes. Set `ttl` on the block for every read, or on one read:

```elixir
cache do
  ttl :timer.hours(1)

  read :get_by_sku
  read :featured, ttl: :timer.minutes(1)
end
```

`get_by_sku` keeps results for an hour, `featured` for a minute.

### Cache a generic action

For example, a call to another company's API:

```elixir
cache do
  action :get_rate, ttl: :timer.minutes(10)
end
```

On a cache hit, the action's `run` function is not called.

### Cache a slow calculation

A calculation written as an Elixir module is cached one result per record:

```elixir
cache do
  calculation :shipping_quote, ttl: :timer.hours(1)
end
```

Writes don't clear these results; they run out with their `ttl`. See
"A slow calculation" in [Examples](documentation/topics/examples.md).

### Clearing the cache

Writes through Ash clear the cache by themselves. To clear it when a
related resource changes, or by hand after an import, see
[When the cache clears](documentation/topics/clearing.md).

## Learn more

- [Examples](documentation/topics/examples.md): the `cache` block for common
  app features, and when not to cache.
- [When the cache clears](documentation/topics/clearing.md): what clears
  it, related resources, and clearing by hand.
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
  resource clears every cached read and generic action of that resource.
- **Values computed from another resource need it listed.** Related
  records loaded with `load` are always read fresh. A count, a sum or a
  filter over another resource is cached only when that resource is in
  `clear_when_changed`; otherwise the read is not cached.
- **The default store is per server.** On several servers, a write clears
  the cache only on the server that made it. Sharing one cache between
  servers is experimental and not tested on real servers; see
  [Storage](documentation/topics/storage.md#running-on-several-servers-experimental).
- **Cached calculations are not cleared by writes.** A changed record gets
  a new result at once, but a calculation that reads something outside the
  record (an API, the clock) can serve an old answer until its `ttl` runs
  out.
- **`ttl: :infinity` holds memory.** A write doesn't delete old results,
  it only stops them being used. They stay in memory until their `ttl`
  runs out, so use `:infinity` only for data that is rarely written.
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
