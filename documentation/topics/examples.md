# Examples

Each section below is a feature you might have in your app, with the
`cache` block for it and why it is set up that way. Every option is listed
in the [DSL reference](../dsls/DSL-AshCache.Resource.md).

Each example sets `ttl` on purpose. A read without one keeps its results
for 5 minutes, or for the `cache` block's `ttl` if you set one.

Two things apply to every example:

- A cached result is thrown away when the resource is changed through Ash,
  when its `ttl` runs out, or when you call `AshCache.invalidate/1`.
  Changes to other resources don't throw it away.
- The default store keeps each server's cache in its own memory. If your
  app runs on several servers, a write clears the cache only on the server
  that made it, and the others serve the old result until `ttl` runs out.
  See [Storage](storage.md).

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
would be happy to print as "updated every minute".

Don't cache numbers that someone acts on right away, such as an account
balance before a transfer or a usage limit that blocks requests.

## Data from another service

Exchange rates, weather or shipping prices fetched from an outside API
through a read action with `manual` (a read you write yourself instead of
a database query).

```elixir
cache do
  read :latest, ttl: :timer.minutes(10)
end
```

A cache hit skips your `manual` read too, so the outside API is called at
most once per `ttl` for each set of arguments. This is often the biggest
win, because outside APIs are slow and may charge per call or limit how
often you can call them. Nothing in your app writes this data, so the
`ttl` is the only thing that refreshes it.

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
