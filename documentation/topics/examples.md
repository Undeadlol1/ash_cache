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
    read :get_by_sku, ttl: :timer.hours(1)
  end
end
```

Every other read on the resource goes straight to the database.

## Data that also changes outside Ash

A table that a nightly import or another service also writes to. AshCache
only notices writes made through Ash, so the other writes show up once the
cached entry expires. Set `ttl` to the longest delay you can accept.

```elixir
cache do
  read :read, ttl: :timer.minutes(2)
end
```

## Refresh the cache right after each write

A settings resource that is read on every request and rarely updated.
Without `warm`, the first read after an update goes to the database. With
it, the update refreshes the cache before it returns.

```elixir
cache do
  read :get_by_key, ttl: :timer.hours(1)
  warm :get_by_key, args: [key: :key]
end
```

`args` says which attribute of the saved record fills each argument of the
read.

The refreshed entry is saved for the actor that `warm` reads as, which is
no actor by default. So `warm` only helps if the read is normally called
the same way. If your app always reads settings as one system actor, give
`warm` a function that returns that actor:

```elixir
warm :get_by_key, args: [key: :key], actor: {MyApp.SystemActor, :new, []}
```

## Clear one resource without touching the rest

`AshCache.clear_store/1` empties a whole store. Give a resource its own
store so you can empty it alone.

```elixir
cache do
  store :products_cache
  read :read, ttl: :timer.minutes(10)
end
```

```elixir
AshCache.clear_store(:products_cache)
```

## Skip the cache for one query

A report that must see the latest data, on a resource that is otherwise
cached.

```elixir
MyApp.Shop.Product
|> Ash.Query.set_context(%{ash_cache: :bypass})
|> Ash.read!()
```

The query reads from the database and saves nothing.

## Clear the cache by hand

After a bulk import done with raw SQL, clear the resource yourself. This
does exactly what a write through Ash does.

```elixir
AshCache.invalidate(MyApp.Shop.Product)
```

## Turn caching off in one environment

For example, in a staging environment where you want every read to hit the
database:

```elixir
# config/staging.exs
config :ash_cache, adapter: AshCache.Store.Adapters.Noop
```

## Use your own storage

Point AshCache at your own adapter module. The
[Storage](storage.md) guide shows how to write one.

```elixir
config :ash_cache, adapter: MyApp.MyCacheAdapter
```
