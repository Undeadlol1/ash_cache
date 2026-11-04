# Examples

Each section below is a feature you might have in your app, with the
`cache` block for it and why it is set up that way. Every option is listed
in the [DSL reference](../dsls/DSL-AshCache.Resource.md).

Each example sets `ttl` on purpose. A read without one keeps its results
for 5 minutes, or for the `cache` block's `ttl` if you set one.

Two things apply to every example:

- A cached result is thrown away when the resource is changed through Ash,
  and in a few other cases listed in [When the cache clears](clearing.md).
- The default store keeps each server's cache in its own memory. If your
  app runs on several servers, a write clears the cache only on the server
  that made it, and the others serve the old result until `ttl` runs out.
  Sharing one cache between servers is experimental; see
  [Running on several servers](storage.md#running-on-several-servers-experimental).

## Blog posts and help pages

Pages that editors change a few times a week and visitors read all day.

```elixir
defmodule MyApp.Content.Post do
  use Ash.Resource,
    domain: MyApp.Content,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_slug, ttl: :timer.hours(24)
    read :published, ttl: :timer.hours(24)
  end
end
```

Editors change posts through Ash, and each change clears the cache, so a
long `ttl` costs nothing in freshness. Results are cached per actor: all
signed-out visitors share one entry, but each signed-in user gets their own.

Don't cache the editor's draft view. Editors expect to see what they just
typed, and the draft list is read far less than the public pages.

## Countries, currencies and pricing plans

Short lists that fill dropdowns and pricing pages and almost never change.

```elixir
cache do
  read :read, ttl: :timer.hours(24)
end
```

These lists are read on many pages and changed maybe once a year, which is
the best case for a cache.

Don't cache the read that decides what a customer is charged at checkout.
If a price changes on one server, another server could still charge the old
price until `ttl` runs out.

## Product catalog: lookup by SKU and a "best sellers" list

A shop that looks products up by SKU on every product page, and shows a
list of best sellers ranked by this week's orders.

```elixir
defmodule MyApp.Shop.Product do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_sku, ttl: :timer.hours(1)
    read :best_sellers, ttl: :timer.minutes(5), cache_empty?: true
  end
end
```

The SKU lookup only changes when the product changes, and that write clears
the cache, so it can live for an hour. The best-seller ranking comes from
orders, which are a different resource: new orders do not clear the
product cache, so the `ttl` of 5 minutes is how old the ranking can get.
`cache_empty?: true` keeps an empty list too, so a quiet week does not send
every page view to the database.

Don't cache stock counts or "only 2 left" at checkout. They change with
every order, and a stale count sells items you no longer have. Read them
with the cache skipped (see "A report that must be exact" below), or keep
them on a resource you don't cache.

## Settings shared by the whole app

Feature flags or site settings that every request reads, and that look the
same for every user.

```elixir
cache do
  read :get_by_key, ttl: :timer.hours(1)
  recache_after_write :get_by_key
end
```

Changing a setting clears the cache, so normally the next request has to
read it from the database. `recache_after_write` caches the read again right
after the write, so the next request finds the new value already cached.

The read's `key` argument comes from the `key` field of the setting you just
wrote, because the names match.

`recache_after_write` reads with no user signed in, so it only helps if your
app also reads settings that way. If it reads them as a user, leave
`recache_after_write` out.

If you run several servers, the others keep the old value for up to `ttl`.
For a flag that must switch off right away, such as a kill switch, use a
short `ttl` or don't cache it.

## Each user's own settings or feature flags

Preferences or per-user flags read on every request for the signed-in user.

```elixir
cache do
  read :for_current_user, ttl: :timer.minutes(30)
end
```

The cache key includes the actor, so each user gets their own entry, and
one user's settings can never be served to another. Pass the user as the
actor when you read, for example through a code interface or
`Ash.Query.for_read(query, :for_current_user, %{}, actor: user)`.

There is no `recache_after_write` here: it reads with no user signed in, so
it would cache an entry that no user's request looks up.

Any user saving their settings clears the cached settings of all users,
because clearing works per resource. If many users change settings all the
time, measure whether the cache still helps.

## A multi-tenant app

Each customer company (tenant) has its own projects, and every page lists
the current tenant's projects.

```elixir
cache do
  read :read, ttl: :timer.minutes(15)
end
```

The cache key includes the tenant, so one company never sees another's
cached results. Pass the tenant as you already do for Ash
(`Ash.read(query, tenant: org_id)` or the `tenant:` option on a code
interface).

A write in any tenant clears the cache for all tenants of that resource.
In an app with many busy tenants, that can mean most reads miss.

## Data from another service

An exchange rate, a weather forecast or a shipping price that your app gets
from another company's API. In Ash such a call is usually a generic action.

```elixir
defmodule MyApp.Money.ExchangeRate do
  use Ash.Resource,
    domain: MyApp.Money,
    extensions: [AshCache.Resource]

  cache do
    action :get_rate, ttl: :timer.minutes(10)
  end

  actions do
    action :get_rate, :decimal do
      argument :from, :string, allow_nil?: false
      argument :to, :string, allow_nil?: false

      run fn input, _context ->
        MyApp.RatesApi.fetch(input.arguments.from, input.arguments.to)
      end
    end
  end
end
```

The first call for a pair of currencies calls the API. For the next 10
minutes, calls with the same arguments get the saved rate, and the `run`
function is not called. This is often the biggest win, because outside APIs
are slow and may charge per call or limit how often you can call them.

Each set of arguments, each actor and each tenant gets its own entry.
AshCache cannot see when the other service changes its data, so `ttl` is
how old a rate can get.

Errors are not saved, so a failed call is tried again next time. `nil` is
never saved, and `[]` is saved only with `cache_empty?: true`. Ash still
checks the resource's policies on every call, also when the answer comes
from the cache.

The action must have a return type. An action whose `run` is a Reactor
cannot be cached; call the Reactor from a `run` function instead. If the
call is a read action with `manual` (a read you write yourself instead of a
database query), cache it with `read` instead of `action`.

Don't cache the rate a customer is charged with. Skip the cache for that
call:

```elixir
MyApp.Money.ExchangeRate
|> Ash.ActionInput.for_action(:get_rate, %{from: "EUR", to: "USD"},
  context: %{ash_cache: :bypass}
)
|> Ash.run_action!()
```

## A slow calculation

A shipping quote that takes a second to work out, shown on every order page.
The calculation is an Elixir module that only looks at the shipment:

```elixir
defmodule MyApp.Shipping.Quote do
  use Ash.Resource.Calculation

  @impl true
  def calculate(shipments, _opts, _context) do
    {:ok, Enum.map(shipments, &MyApp.Shipping.Rates.quote(&1.weight_grams, &1.destination))}
  end
end

defmodule MyApp.Shipping.Shipment do
  use Ash.Resource,
    domain: MyApp.Shipping,
    extensions: [AshCache.Resource]

  cache do
    calculation :shipping_quote, ttl: :timer.hours(1)
  end

  attributes do
    uuid_primary_key :id
    attribute :weight_grams, :integer
    attribute :destination, :string
  end

  calculations do
    calculate :shipping_quote, :decimal, MyApp.Shipping.Quote
  end
end
```

Each shipment has its own entry. The first `Ash.load!(shipment, :shipping_quote)`
runs the calculation. Loads in the next hour find the saved quote. When you
load the quote for a list of shipments, only the ones not yet saved are
calculated.

The key holds the arguments, the actor, the tenant, every attribute of the
shipment and every field the calculation's `load/3` asks for. Edit the
weight and the next load is a new key, so you never see a quote for the old
weight. The old entry is not deleted; it expires after an hour. Writes don't
clear calculation entries.

Use this only for a calculation that depends on the record alone. If it
reads something else, such as a carrier's API or the current time, the
cache can't see that change and serves the old answer until the `ttl` runs
out. Changing any attribute, even one the calculation doesn't use, makes it
run again. Identical misses at the same moment each run the calculation.

Only module calculations can be cached. An expression calculation already
runs in the database, and it is saved inside the cached read that loads it.
Naming one in the `cache` block is a compile error.

To skip the cache for one load:

```elixir
Ash.load!(shipment, :shipping_quote, context: %{ash_cache: :bypass})
```

## Reads that include another resource

Related records loaded with `load` are read fresh on every request, cache
hit or not: a post's comments, a product's prices, an order's items, a
profile's avatar. They need nothing.

Values computed from another resource are part of the cached rows: counts
and sums (aggregates), calculations that use them or reach another
resource, and filters, sorts or policies that reach another resource.
AshCache caches such a read only when every resource it reaches is in
`clear_when_changed`. Otherwise the read goes to the database every time,
so it is never stale. List each resource on the path, including the join
resource of a `many_to_many`.

Each listed resource needs the extension, even if it caches nothing. The
rules are in [When the cache clears](clearing.md#related-resources).

## A blog post with its comments

A post page that shows the post and its comments.

```elixir
cache do
  read :get_by_slug, ttl: :timer.hours(1)
end
```

```elixir
MyApp.Blog.Post
|> Ash.Query.for_read(:get_by_slug, %{slug: slug})
|> Ash.Query.load(:comments)
|> Ash.read_one!()
```

The post comes from the cache and its comments from the database, so a new
comment shows up on the next page view without listing anything.

## Team dashboard and its members

A dashboard that shows a team with its member count and member list.

```elixir
cache do
  read :dashboard, ttl: :timer.hours(1)
  clear_when_changed [MyApp.Teams.Membership]
end
```

The member count is an aggregate over memberships, so `Membership` is
listed: each join or leave throws away the cached dashboard. People join
and leave teams a few times a day, so a long `ttl` is fine. Without the
listing, the dashboard is not cached at all.

## Data that also changes outside Ash

A table that a nightly CSV import, a script with raw SQL or another service
also writes to.

```elixir
cache do
  read :read, ttl: :timer.minutes(10)
end
```

AshCache only sees writes made through Ash. Other writes show up when the
entry expires, so set `ttl` to the longest delay you can accept. If you
control the import, clear the cache when it finishes:

```elixir
MyApp.Import.run!()
AshCache.invalidate(MyApp.Shop.Product)
```

`AshCache.invalidate/1` does exactly what a write through Ash does. Like a
write, it clears only the server it runs on.

## A report that must be exact

A finance export or an admin page that must show the database as it is
right now, on a resource that is otherwise cached.

```elixir
MyApp.Shop.Product
|> Ash.Query.for_read(:read, %{}, context: %{ash_cache: :bypass})
|> Ash.read!()
```

The query goes to the database and caches nothing. You can also add the
option with `Ash.Query.set_context/2`, any time before the query runs.
