# Examples

Each section below is a feature you might have in your app, with the
`cache` block for it and why it is set up that way. Every option is listed
in the [DSL reference](../dsls/DSL-AshCache.Resource.md).

Each example sets `ttl` on purpose. A read without one keeps its results
for 5 minutes, or for the `cache` block's `ttl` if you set one.

Two things apply to every example:

- A cached result is thrown away when the resource is changed through Ash,
  when a resource listed in its `clear_when_changed` is changed through Ash,
  when its `ttl` runs out, or when you call `AshCache.invalidate/1`.
  Changes to other, unlisted resources don't throw it away.
- The default store keeps each server's cache in its own memory. If your
  app runs on several servers, a write clears the cache only on the server
  that made it, and the others serve the old result until `ttl` runs out.
  To share one cache between servers, use the Nebulex adapter; see
  [Running on several servers](storage.md#running-on-several-servers).

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

## "Related posts" and other sidebars

A "related posts" or "customers also bought" box shown next to every post or
product. Stack Overflow caches its related-questions sidebar this way.

```elixir
cache do
  read :related, ttl: :timer.minutes(30)
end
```

Each post's sidebar is its own entry, because the post id is an argument
of the read. The list doesn't need to be up to date to the minute, and it is
read on every page view.

## RSS feeds and sitemaps

Feeds and sitemaps that bots and feed readers fetch over and over.

```elixir
cache do
  read :recent_for_feed, ttl: :timer.minutes(15)
end
```

Bots fetch these far more often than you publish. Publishing a post is a
write, so the feed updates right away; the `ttl` only limits how long an
unchanged feed is kept.

## Phoenix LiveView pages

A LiveView page loads its data twice when it opens: once for the first
HTML and once more when the browser connects.

```elixir
cache do
  read :list_for_page, ttl: :timer.seconds(30)
end
```

Even a short `ttl` makes the second load a cache hit, which halves the
database work for every page visit. The two loads run in different
processes on the same server, and the cache is shared by all processes
on a server, so they find each other's entry (as long as they read as the
same actor).

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

## The signed-in user, loaded on every request

Most apps load the current user (and often their roles) at the start of
every request.

```elixir
cache do
  read :get_by_id, ttl: :timer.minutes(5)
end
```

Each user gets their own entry, because the lookup filters by their id.
When any user changes their profile, the cached user reads of all users
are thrown away.

Keep the `ttl` short if you run several servers. Banning or locking a user
is a write, and it throws away the cache only on the server that made it.
The other servers keep letting the user in until the `ttl` runs out.

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

## Popular posts from the last 24 hours

A blog or forum that shows the posts with the most upvotes in the last day.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_slug, ttl: :timer.hours(1)
    read :top_today, ttl: :timer.minutes(1)
  end
end
```

Everyone sees the same cached list, rebuilt at most once a minute. Big
sites work the same way: the top list is rebuilt every so often, not on
every vote. The `ttl` is how often the list refreshes.

Store votes in their own resource (for example `MyApp.Blog.Vote`) and count
them with an aggregate. Votes then don't touch the post cache. If you keep
a `vote_count` field on `Post` instead, every vote is a write to `Post` and
throws away all cached post reads, so with lots of voting the cache is
almost always empty.

## Settings shared by the whole app

Feature flags or site settings that every request reads, and that look the
same for every user.

```elixir
cache do
  read :get_by_key, ttl: :timer.hours(1)
  refresh :get_by_key, arguments: [key: :key], actor: {MyApp.SystemActor, :new, []}
end
```

Without `refresh`, the first request after a change goes to the database.
With it, the update reads the setting again and caches it before it
returns. `arguments` says which field of the saved record fills each argument of
the read. `refresh` caches the result only for the actor it reads as (no actor
unless you set `actor`), so it only helps if your app always reads settings
as that same actor.

Don't rely on this to switch off something urgent, like a kill switch for a
broken payment provider, when you run several servers. The other servers
keep the old value for up to `ttl`. Use a short `ttl` for those flags, or
skip the cache for them.

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

There is no `refresh` here. `refresh` reads as one fixed actor, so it would cache
an entry that no user's request ever looks up.

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
In an app with many busy tenants, that can mean most reads miss. `refresh`
works on a multi-tenant resource: it refreshes the cache for the tenant of the record that
was written. Other tenants' entries are cleared and fill on their next read.

## Dashboard numbers and leaderboards

A team dashboard that shows totals counted from other resources, or a
leaderboard of players by points won in matches.

```elixir
cache do
  read :dashboard, ttl: :timer.minutes(1)
end
```

Numbers like these are usually counts or sums of other records, loaded
with Ash aggregates. Writes to those other records do not clear this
resource's cache, so the numbers are up to `ttl` old. Pick the `ttl` you
would be happy to print as "updated every minute". If the other records
change rarely, list them in `clear_when_changed` instead (see "Team
dashboard and its members" below).

Don't cache numbers that someone acts on right away, such as an account
balance before a transfer or a usage limit that blocks requests.

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

The sections below cache reads that `load` records of another resource.
Without `clear_when_changed`, a change to those records shows up only when
`ttl` runs out. With it, the change throws away the cached reads right away.

Each resource listed in `clear_when_changed` needs the extension, even if it
caches nothing:

```elixir
defmodule MyApp.Blog.Comment do
  use Ash.Resource,
    domain: MyApp.Blog,
    extensions: [AshCache.Resource]
end
```

Clearing is per resource, here too: a new comment on one post throws away
the cached reads of every post. If the listed resource is written to all
the time, most reads will miss. Measure first.

## A blog post with its comments

A post page that shows the post and its comments.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_slug_with_comments, ttl: :timer.hours(1)
    clear_when_changed [MyApp.Blog.Comment]
  end
end
```

A new, edited or deleted comment shows up on the next page view instead of
an hour later.

## A product with its prices

A product page that loads the product's prices, kept as their own records
(one per currency or per customer group).

```elixir
cache do
  read :get_by_sku, ttl: :timer.hours(1)
  clear_when_changed [MyApp.Shop.Price]
end
```

A price change throws away the cached product page, so visitors see the new
price on their next view. On several servers the other servers still show
the old price until `ttl` runs out, so read the price you charge with the
cache skipped.

## A customer's order list with the items in each order

A "My orders" page that lists a customer's orders and the items in each.

```elixir
defmodule MyApp.Shop.Order do
  use Ash.Resource,
    domain: MyApp.Shop,
    extensions: [AshCache.Resource]

  cache do
    read :for_customer, ttl: :timer.minutes(30)
    clear_when_changed [MyApp.Shop.OrderItem]
  end
end
```

Adding, changing or removing an item throws away
the cached list. Each customer still gets their own entry, because the
actor is part of the key.

## A user profile with its avatar

A profile card shown next to every comment and message, with the avatar
stored as its own resource.

```elixir
cache do
  read :get_profile, ttl: :timer.hours(6)
  clear_when_changed [MyApp.Accounts.Avatar]
end
```

A new avatar shows up right away instead of hours later.

## Team dashboard and its members

A dashboard that shows a team with its member count and member list.

```elixir
cache do
  read :dashboard, ttl: :timer.hours(1)
  clear_when_changed [MyApp.Teams.Membership]
end
```

People join and leave teams a few times a day, so a long `ttl` is fine:
each join or leave throws away the cached dashboard.

## A restaurant menu with its dishes

A menu page that lists the dishes on the menu, each a record of its own.

```elixir
cache do
  read :get_with_items, ttl: :timer.hours(12)
  clear_when_changed [MyApp.Menus.MenuItem]
end
```

A dish that sold out or changed price shows up right away. A dish
written by the nightly import does not, because the import does not go
through Ash: call `AshCache.invalidate(MyApp.Menus.MenuItem)` after it.
That throws away the cached menus too.

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

## A personal feed that changes all the time

Each user's home feed, order history or inbox, on a resource that many
users write to every second.

Don't cache it with AshCache. Any write clears the cached reads of every
user, so with constant writes almost every read is a miss, and each write
gets slower. Shopify hit the same problem with the home feed of its Shop
app and built a cache that is cleared per user instead.

## Things not worth caching

- **Search results and filtered lists.** Each search term and filter is its
  own entry, so the same entry is rarely read twice.
- **Data written about as often as it is read**, such as a "last seen"
  timestamp. Every write clears the cache, so most reads miss and every
  write gets slower.
- **Anything that must be exact when it is used**: stock at checkout,
  balances, the price being charged.
- **Counters that change on every request**, such as rate limits or view
  counts. They are written as often as they are read.
