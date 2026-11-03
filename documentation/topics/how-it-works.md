# How AshCache works

This page explains what AshCache does on a read, what it does on a write,
and why it has the limits it has.

## On a read

Every read listed with `read` in the `cache` block gets a step that runs before the database is
asked anything. The step builds a key from the query and looks it up in
the cache.

- If the key is found, the stored records are returned and the database
  is not called.
- If it is not found, the read runs as normal. If it returned at least one
  record, the result is saved under that key.

### When many requests miss at once

When a popular entry runs out or is cleared, many requests can miss it at
the same moment. Only the first one asks the database. The others on the
same server wait for its records and return those. They share only when
their keys are equal, so two users, or two tenants, never get each other's
records.

If that first request fails or its process dies, one of the waiting
requests asks the database instead. If it takes longer than 5 seconds, the
waiting requests stop waiting and each ask the database themselves. Change
the limit with:

```elixir
config :ash_cache, rebuild_timeout: :timer.seconds(10)
```

This happens on each server separately, whatever the store: with several
servers, each one asks the database at most once per key at a time.

Empty results are not saved by default. Otherwise a record that does not
exist yet would keep being reported as missing until the entry expired.
Set `cache_empty?: true` on the `read` to save them anyway.

## What is in a key

A key is built from:

1. the resource,
2. the resource's current **version value** (explained below), and the
   version value of each resource listed in `clear_when_changed`,
3. the name of the read action,
4. everything about the query that affects its result: arguments, filter,
   sort, limit, offset, page, distinct, select and load,
5. the current actor and tenant.

Because the whole query is in the key, a lookup by id, a filtered list and
page two of a list each get their own entry.

Because the actor is in the key, a cached result can only be returned to
the user who read it in the first place. Ash applies its policy filters to
the query before the key is built, so a read made with `authorize?: false`
gets a different key from the same user's normal read and can never answer
it.

## On a write

Each resource has a version value stored in the cache next to its
entries. The value is part of every key.

When a create, update or destroy succeeds, AshCache replaces the value with
a new one that has never been used. Every key built with the old value is
now never looked up again, so all
of that resource's cached reads are gone in one step, however many there
were. The old entries are not deleted; they expire on their own.

If the store loses the value (it was evicted, or the store restarted),
AshCache picks a new one too. Values are random and never reused, so a lost
value can only cause misses, never bring back old entries. See
[Storage](storage.md#a-lost-entry-never-brings-back-old-data).

The value is replaced after the database transaction commits, not before.
A write that is rolled back never reaches that point, so it cannot leave
wrong data in the cache.

This is also why the cache clears per resource rather than per record:
keys are built from whatever query was run, so a write cannot know which
entries contain the record it changed.

## Clearing when another resource changes

```elixir
# On MyApp.Blog.Post
cache do
  read :get_by_slug, ttl: :timer.hours(1)
  clear_when_changed [MyApp.Blog.Comment]
end
```

Every cached post key also contains the comment resource's version value.
A comment write replaces that value, after commit like any other write, so
every post key built before it is never looked up again. A rolled-back
comment write does not replace it.

The comment resource needs `extensions: [AshCache.Resource]`, because that
is what makes its writes replace its version value. It does not need a
`cache` block. It works like Rails' `belongs_to :post, touch: true`, where
saving a comment updates the post's `updated_at` and so changes the post's
cache key. AshCache changes the key without writing to the post.

Some things follow from this:

- The `[:ash_cache, :invalidate]` event is sent for the comment resource,
  not for the post. The post's next read is a miss.
- `AshCache.invalidate(MyApp.Blog.Comment)` clears cached post reads too.
- It is not passed along. If `Post` lists `Comment` and `Comment` lists
  `Author`, an author write does not clear posts. List `Author` on `Post`
  too.
- It is per resource too. A comment on one post clears the cached reads of
  every post.
- Each cached post read looks up one more version value per listed
  resource.

## Filling the cache right after a write

Normally the first read after a write goes to the database. A `refresh`
declaration moves that cost to the writer:

```elixir
cache do
  read :get_by_sku, ttl: :timer.hours(1)
  refresh :get_by_sku, arguments: [sku: :sku]
end
```

After each successful create or update, AshCache runs the named read with
arguments taken from the saved record, so the new value is cached before
anyone asks for it. The read is a real read action, with the same key and
the same authorization as any other. It runs inside the write, so each
`refresh` makes the write one read slower. If the read fails, the failure is
logged and ignored; the version bump has already removed the stale entry.

## Seeing what the cache does

Each cached read sends a `:telemetry` event: `[:ash_cache, :read, :hit]`
when the result came from the cache, `[:ash_cache, :read, :miss]` when it
went to the database. Each clear sends `[:ash_cache, :invalidate]`. Attach
a handler to count hit rates in production. The events and their metadata
are listed in `AshCache`; for tests, use `AshCache.Testing` (see
[How to test with AshCache](testing.md)).

## Ways around the cache

In order from smallest to largest:

1. **Options in the `cache` block.** See the
   [DSL reference](../dsls/DSL-AshCache.Resource.md).
2. **Skip the cache for one query.** Pass `context: %{ash_cache: :bypass}`
   when you build the query, or add it with `Ash.Query.set_context/2` before
   the query runs. It reads from the database and saves
   nothing.
3. **Clear by hand.** `AshCache.invalidate(resource)` does what a write
   does. `AshCache.clear_store(store)` empties a whole store.
4. **Use a different store.** See the [Storage](storage.md) guide.

## Limits

- **Related records can go stale.** `load` is part of the key, so an entry
  can contain related records. A write to the related resource changes its
  own version value, not the parent's, so the parent entry keeps serving the
  old related records until it expires. List the related resource in
  `clear_when_changed` to fix this.
- **Writes get slower.** Every write stores a new value in the cache. In one
  write-heavy test suite, caching the resource roughly doubled the suite's
  runtime. Measure before caching a resource that is written to constantly.
- **No clearing per record.** See "On a write" above.
