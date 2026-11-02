# Examples

One `cache` block for each common situation. Combine them as you need.
Every option is listed in the [DSL reference](../dsls/DSL-AshCache.Resource.md).

## Cache one lookup

A product catalogue that is looked up by SKU thousands of times a minute.
Its list and search results change too often to be worth caching, so only
the lookup is listed.

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
    reads [:get_by_sku]
  end
end
```

Every other read on the resource goes straight to the database.

## Cache several reads

List each one.

```elixir
cache do
  reads [:read, :get_by_sku, :featured]
end
```

## Short TTL for data that changes outside Ash

A table that a nightly import or another service also writes to. AshCache
only notices writes made through Ash, so the expiry time is the longest
those other writes can stay invisible.

```elixir
cache do
  reads [:read]
  ttl :timer.minutes(2)
end
```

## Re-cache right after each write

A settings resource that is read on every request and rarely updated.
Without `warm`, the first read after an update goes to the database. With
it, the update refreshes the cache before it returns.

```elixir
cache do
  reads [:get_by_key]
  warm :get_by_key, args: [key: :key]
end
```

`args` says which attribute of the saved record fills each argument of the
read. If the read needs an actor, name a function that returns one:

```elixir
warm :get_by_key, args: [key: :key], actor: {MyApp.SystemActor, :new, []}
```

## A separate store for one resource

A store can be emptied as a whole with `AshCache.clear_store/1`. Give a
resource its own store to empty it without touching anything else, or to
watch its size on its own.

```elixir
cache do
  reads [:read]
  store :products_cache
end
```

## Multi-tenant and per-actor data

The tenant and the user are always part of the cache key, so two tenants
or two users running the same query never share an entry.

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

The query reads from the database and saves nothing.

## Invalidate from outside a write

After a bulk import done with raw SQL, or from a support task, clear the
resource by hand. This does exactly what a successful write does.

```elixir
AshCache.invalidate(MyApp.Shop.Product)
```

To empty a whole store, including every resource that uses it:

```elixir
AshCache.clear_store(:ash_cache)
```

## Turn caching off in one process

A migration script or a test that must read fresh data every time.

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

To turn it off for the whole application instead, set the adapter in config:

```elixir
config :ash_cache, adapter: AshCache.Store.Adapters.Noop
```

## Bring your own store

An adapter is four functions. A missing key returns `{:ok, nil}`, never an
error.

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

Whatever a resource puts in `adapter_options` reaches your `put/4` as
`opts`, next to `:ttl`:

```elixir
cache do
  reads [:read]
  adapter_options prefix: "products"
end
```
