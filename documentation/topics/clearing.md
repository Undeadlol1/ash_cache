# When the cache clears

AshCache throws a cached result away when the data behind it may have
changed. Most of the time you don't need to do anything. This page lists
when it happens, and what to do in the cases AshCache can't see.

## What clears the cache

A cached result is thrown away when:

1. **The resource is changed through Ash.** Creating, updating or deleting
   any product throws away every cached product read and generic action,
   right away.
2. **A resource listed in `clear_when_changed` is changed through Ash.**
   See [Related resources](#related-resources).
3. **Its `ttl` runs out**, even if nothing changed.
4. **You clear it by hand** with `AshCache.invalidate/1` or
   `AshCache.clear_store/1`. See [Clear by hand](#clear-by-hand).

Nothing else clears it. A change made without Ash, such as raw SQL, an
import script or another service writing to the same table, shows up only
when `ttl` runs out.

## A write clears the whole resource

Any write to a resource clears every cached read of that resource, not
only the entries that contain the changed record. Updating one product
clears the cached lookup of every product.

AshCache can't do better than this: an entry is saved under the query that
produced it, so a write can't tell which entries hold the record it
changed. If a resource is written to all the time, most reads will miss.
Measure before caching it.

## Writes that fail don't clear anything

The cache is cleared after the database transaction commits. A write that
fails or is rolled back leaves the cache as it was, so it can never leave
wrong data cached.

## Related resources

Related records loaded with `load`, such as a post's comments, are read
fresh on every request. They need nothing.

Values computed from another resource are different: a post's comment
count, or a filter on its comments. They are saved with the cached post, so
AshCache caches such a read only when the other resource clears it.
Otherwise the read goes to the database every time. To cache it, list the
comment resource on the post:

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    extensions: [AshCache.Resource]

  cache do
    read :get_by_slug
    clear_when_changed [MyApp.Blog.Comment]
  end
end

defmodule MyApp.Blog.Comment do
  use Ash.Resource,
    domain: MyApp.Blog,
    extensions: [AshCache.Resource]
end
```

Now creating, updating or deleting any comment clears every cached post
read, the same way a change to a post does.

Things to know:

- **The listed resource needs the extension**, so AshCache sees its writes.
  It doesn't need a `cache` block. Without the extension, `Post` fails to
  compile.
- **It is per resource.** A comment on one post clears the cached reads of
  every post.
- **It is not passed along.** If `Post` lists `Comment` and `Comment` lists
  `Author`, an author change does not clear posts. List `Author` on `Post`
  too.
- **List the join resource for many-to-many.** If posts and tags are
  linked through a `PostTag` resource, tagging a post writes a `PostTag`,
  not a `Tag`. List `PostTag`, and `Tag` too if tag names can change.
- **Deletes done by the database are not seen.** If deleting a post makes
  the database delete its comments (`ON DELETE CASCADE`), and `Comment`
  caches its own reads, those keep the deleted comments. Add `clear_when_changed [MyApp.Blog.Post]`
  to `Comment`, so deleting a post clears them.
- **Foreign key names don't matter.** Only the resource is listed, so a
  relationship on any column works the same.
- **Clearing the listed resource by hand clears the post too.**
  `AshCache.invalidate(MyApp.Blog.Comment)` throws away cached post reads.
- **Each listed resource makes cached reads a little slower**: one more
  value is looked up in the store per read.

The [Examples](examples.md#reads-that-include-another-resource) page has
more cases: a post with its comments, and a team with its members.

## Clear by hand

When data changes without Ash, for example after an import, clear the
resource yourself:

```elixir
MyApp.Import.run!()
AshCache.invalidate(MyApp.Shop.Product)
```

`AshCache.invalidate/1` does exactly what a write through Ash does: it
clears the resource's cached reads and those of any resource that lists it
in `clear_when_changed`.

To empty a whole store, for every resource in it, use
`AshCache.clear_store(:ash_cache)`. To empty one resource's cache without
touching the rest, give it its own store; see
[Storage](storage.md#give-a-resource-its-own-store).

## On several servers

With the default store, each server keeps its own cache. A write, or a call
to `AshCache.invalidate/1`, clears the cache only on the server where it
ran. The other servers serve old results until `ttl` runs out. Sharing one
cache between servers is experimental; see
[Running on several servers](storage.md#running-on-several-servers-experimental).

## Cache a read again after a write

After a write, the next read goes to the database. If that first read must
be fast, `recache_after_write` caches the read again as part of the write:

```elixir
cache do
  read :get_by_sku
  recache_after_write :get_by_sku
end
```

Here a write means a create or an update; a delete caches nothing again.

Each argument of the read comes from the field of the written record with
the same name: the read's `sku` argument gets the product's `sku`. If the
names differ, say which field to use:

```elixir
recache_after_write :get_by_code, arguments: [code: :sku]
```

If an argument the read needs has no field to come from, your app doesn't
compile.

Each `recache_after_write` makes the write one read slower. If the read
fails, the failure is logged and the write still succeeds.

## How it works

How clearing works inside, with version values in every key, is explained
in [How AshCache works](how-it-works.md#on-a-write).
