# How AshCache works

This page explains what AshCache does on a read, on a generic action call
and on a write, and why it has the limits it has.

## On a read

Every read listed with `read` in the `cache` block gets a step that runs before the database is
asked anything. The step builds a key from the query and looks it up in
the cache.

- If the key is found, the stored records are returned and the database
  is not called.
- If it is not found, the read runs as normal. If it returned at least one
  record, the result is saved under that key.

Empty results are not saved by default. Otherwise a record that does not
exist yet would keep being reported as missing until the entry expired.
Set `cache_empty?: true` on the `read` to save them anyway.

## On a generic action call

Ash has no step that can skip a generic action's `run` function. So for
each `action` in the `cache` block, AshCache puts its own `run` in place of
the action's own one when the resource compiles. Ash checks policies before
it calls `run`, so they are checked on every call.

- If the key is found, the stored result is returned and the action's own
  `run` is not called.
- If it is not found, the action's own `run` is called. If it succeeded,
  its result is saved under that key.

Errors and `nil` are never saved. `[]` is saved only with
`cache_empty?: true`.

## What is in a key

A key is built from:

1. the resource,
2. the resource's current **version value** (explained below),
3. the name of the action,
4. for a read, everything about the query that affects its result:
   arguments, filter, sort, limit, offset, page, distinct, select and load.
   For a generic action, its arguments,
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
of that resource's cached reads and generic actions are gone in one step,
however many there were. The old entries are not deleted; they expire on their own.

The value is replaced after the database transaction commits, not before.
A write that is rolled back never reaches that point, so it cannot leave
wrong data in the cache.

This is also why the cache clears per resource rather than per record:
keys are built from whatever query was run, so a write cannot know which
entries contain the record it changed.

## Filling the cache right after a write

Normally the first read after a write goes to the database. A `warm`
declaration moves that cost to the writer:

```elixir
cache do
  read :get_by_sku, ttl: :timer.hours(1)
  warm :get_by_sku, args: [sku: :sku]
end
```

After each successful create or update, AshCache runs the named read with
arguments taken from the saved record, so the new value is cached before
anyone asks for it. The read is a real read action, with the same key and
the same authorization as any other. It runs inside the write, so each
`warm` makes the write one read slower. If the read fails, the failure is
logged and ignored; the version bump has already removed the stale entry.

## Seeing what the cache does

Each cached read sends a `:telemetry` event: `[:ash_cache, :read, :hit]`
when the result came from the cache, `[:ash_cache, :read, :miss]` when it
went to the database. Each cached generic action sends
`[:ash_cache, :action, :hit]` or `[:ash_cache, :action, :miss]` the same
way. Each clear sends `[:ash_cache, :invalidate]`. Attach
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
   nothing. For a generic action, pass the same context to
   `Ash.ActionInput.for_action/4` or use `Ash.ActionInput.set_context/2`.
3. **Clear by hand.** `AshCache.invalidate(resource)` does what a write
   does. `AshCache.clear_store(store)` empties a whole store.
4. **Use a different store.** See the [Storage](storage.md) guide.

## Limits

- **Related records can go stale.** `load` is part of the key, so an entry
  can contain related records. Version values are per resource, though.
  A write to the related resource changes its own version, not the parent's,
  so the parent entry keeps serving the old related records until it
  expires. Keep `load` off cached reads, or treat `ttl` as how stale that
  data may get.
- **Writes get slower.** Every write stores a new value in the cache. In one
  write-heavy test suite, caching the resource roughly doubled the suite's
  runtime. Measure before caching a resource that is written to constantly.
- **No clearing per record.** See "On a write" above.
