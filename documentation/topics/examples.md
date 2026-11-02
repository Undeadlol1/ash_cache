# Examples

Each example is a complete `cache` block for one situation. Mix and match;
every option is documented in the [DSL reference](../dsls/DSL-AshCache.Resource.md).

## Cache everything with the defaults

The common case. Every read action cached for one hour, invalidated by every
write to this resource.

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
  end
end
```

## Cache only one lookup

A catalogue that is read by SKU thousands of times a minute, while list and
search queries change too often to be worth caching.

```elixir
cache do
  reads [:get_by_sku]
end
```

Every other read action on the resource goes straight to the data layer.

## Short TTL for data that changes outside Ash

A table that a nightly import or another service also writes to. AshCache
only sees writes that go through Ash actions, so the TTL is the ceiling on
how stale the other writes can appear.

```elixir
cache do
  ttl :timer.minutes(2)
end
```

## Re-cache right after each write

A settings resource that is read on every request and updated rarely. Without
`warm`, the first read after an update pays a database round trip; with it,
the writer refreshes the entry before returning.

```elixir
cache do
  reads [:get_by_key]
  warm :get_by_key, args: [key: :key]
end
```

`args` maps each read argument to an attribute of the written record. When
the read action needs an actor, give a function that returns one:

```elixir
warm :get_by_key, args: [key: :key], actor: {MyApp.SystemActor, :new, []}
```

## A separate store for one resource

Stores are cleared as a whole by `AshCache.clear_store/1`. Giving a resource
its own store lets you wipe it without touching anything else, and lets you
watch its size on its own in Cachex.

```elixir
cache do
  store :products_cache
end
```

`AshCache.Supervisor` starts the extra store on boot with no further wiring.

## Multi-tenant and per-actor data

Nothing to configure. The tenant and the actor are always part of the cache
key, so two tenants or two users reading the same query never share an
entry, and a cached row can only be served back to the actor and tenant that
read it.

```elixir
# These three reads each get their own cache entry.
Ash.read!(Product, tenant: "acme")
Ash.read!(Product, tenant: "globex")
Ash.read!(Product, tenant: "acme", actor: admin)
```

## Skip the cache for one query

A report that must see the latest data, on a resource that is otherwise
cached.

```elixir
Product
|> Ash.Query.set_context(%{ash_cache: :bypass})
|> Ash.read!()
```

The query reads from the data layer and stores nothing.

## Invalidate from outside a write

After a bulk import done with raw SQL, or from a support task, bump the
resource by hand. This does exactly what a successful write does.

```elixir
AshCache.invalidate(MyApp.Shop.Product)
```

To empty a whole store, including every resource that uses it:

```elixir
AshCache.clear_store(:ash_cache)
```

## Turn caching off in one process

A migration script or a test that must read fresh data every time. The
override lives in the process dictionary and dies with the process.

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

To turn it off for the whole application instead, set the adapter in config:

```elixir
config :ash_cache, adapter: AshCache.Store.Adapters.Noop
```

## Bring your own store

Four callbacks make an adapter. A miss is `{:ok, nil}`, never an error.

```elixir
defmodule MyApp.RedisCacheAdapter do
  @behaviour AshCache.Store.Adapter

  @impl true
  def get(store, key), do: MyApp.Redis.get(store, key)

  @impl true
  def put(store, key, value, opts) do
    MyApp.Redis.set(store, key, value, ttl: opts[:ttl], prefix: opts[:prefix])
  end

  @impl true
  def del(store, key), do: MyApp.Redis.del(store, key)

  @impl true
  def clear(store), do: MyApp.Redis.flush(store)
end
```

Select it for the whole application:

```elixir
config :ash_cache, adapter: MyApp.RedisCacheAdapter
```

Anything a resource puts in `adapter_options` is passed to your `put/4` as
`opts`, alongside `:ttl`:

```elixir
cache do
  adapter_options prefix: "products"
end
```
