# AshCache

[![Hex.pm](https://img.shields.io/hexpm/v/ash_cache.svg)](https://hex.pm/packages/ash_cache)
[![HexDocs](https://img.shields.io/badge/hexdocs-ash__cache-blue.svg)](https://hexdocs.pm/ash_cache)
[![CI](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/Undeadlol1/ash_cache/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/ash_cache.svg)](https://github.com/Undeadlol1/ash_cache/blob/main/LICENSE)

Declarative read-through caching for [Ash](https://hexdocs.pm/ash) resources.

Add one empty block to a resource and its reads are cached. Writes to that
resource clear the cache on their own. There is nothing else to wire up.

## Why AshCache

Caching by hand means inventing keys, remembering to clear them on every
write, and hoping nobody reads the data through a query you forgot about.
AshCache uses what Ash already knows about your resource instead:

- **One block caches every read.** Keys are derived from the action and the
  full query (arguments, filter, sort, pagination), so two different queries
  never share an entry.
- **Writes invalidate for you.** Every successful create, update or destroy
  bumps a per-resource generation counter after the transaction commits. A
  rolled-back write changes nothing.
- **Actor and tenant are always part of the key.** A cache hit can only
  return what that same actor and tenant already read through normal
  authorization.
- **Tests stay isolated.** A process-local store adapter gives every
  `async: true` test its own cache with no setup.

## Installation

Add `ash_cache` to your dependencies:

```elixir
def deps do
  [
    {:ash_cache, "~> 0.1"}
  ]
end
```

Start the cache stores from your application's supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {AshCache.Supervisor, otp_app: :my_app}
]
```

That is all the setup. No application config is required.

## Quick start

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
  end
end
```

That is the whole change. Every read action on `Product` is now cached for one
hour, and every write to `Product` invalidates those entries.

Tune it only when you need to:

```elixir
cache do
  ttl :timer.minutes(5)                  # entries live five minutes
  reads [:get_by_sku]                    # cache only this read action
  warm :get_by_sku, args: [sku: :sku]    # re-cache right after each write
end
```

## Guides

### Topics

- [Examples](documentation/topics/examples.md): a `cache` block for each
  common situation, from one cached lookup to a custom store.
- [How It Works](documentation/topics/how-it-works.md): cache keys,
  generation-based invalidation, write-through warming, and the escape hatches.
- [Testing](documentation/topics/testing.md): isolated async tests with the
  process-local adapter.

### Reference

- [DSL: AshCache.Resource](documentation/dsls/DSL-AshCache.Resource.md):
  every option in the `cache` block.
- [Module docs on HexDocs](https://hexdocs.pm/ash_cache).

## Status

Version 0.1. Extracted from a production application, where it caches two
resources. Three limits are deliberate in this version:

- **Invalidation is per resource, not per key.** With automatically derived
  keys, a write cannot know every query shape that cached its resource, so a
  write clears all of that resource's entries.
- **Loaded relationships can go stale.** A write to a related resource bumps
  that resource's counter, not the parent's. Keep `load` off cached reads, or
  accept the TTL as the staleness window.
- **Writes cost a little more.** Every write bumps a counter. One
  write-heavy test suite roughly doubled in runtime after its resource was
  cached. Measure before caching a write-heavy resource.

## For AI assistants

<details>
<summary>Instructions for coding agents (Claude Code, Cursor, Copilot, ...)</summary>
<p>
Everything above is written for people. The text for machines is
<a href="https://github.com/Undeadlol1/ash_cache/blob/main/usage-rules.md"><code>usage-rules.md</code></a>:
a short, imperative set of rules for an agent writing code that uses
AshCache. It ships inside the Hex package, so after <code>mix deps.get</code>
it is at <code>deps/ash_cache/usage-rules.md</code>. Point your agent at that
file, or, if your project already uses the
<a href="https://hexdocs.pm/usage_rules"><code>usage_rules</code></a> package,
add <code>:ash_cache</code> to its list. Nothing is added to your project
unless you do one of those.
</p>
</details>

## License

MIT. See [LICENSE](https://github.com/Undeadlol1/ash_cache/blob/main/LICENSE).
