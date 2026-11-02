# Testing

A shared cache is the enemy of `async: true`: one test's cached read leaks
into another test's assertions. AshCache solves this with a store adapter
that keeps every process's entries in that process's own dictionary.

## Set the adapter

```elixir
# config/test.exs
config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal
```

That is the whole setup. Every test process gets a private, empty cache, so
tests cannot observe each other and need no cleanup.

The `AshCache.Supervisor` can stay in your application's children; the
Cachex stores it starts are simply never used while the process-local adapter
is active.

## Asserting on cache behaviour

Most tests should not care whether a read was served from cache. When one
does, read twice and change the data in between through a path AshCache does
not see, such as a raw repo update. A cached read returns the old value; a
bypassed read returns the new one:

```elixir
query = Ash.Query.set_context(MyApp.Shop.Product, %{ash_cache: :bypass})
```

To invalidate by hand inside a test, call `AshCache.invalidate(resource)`.

## Turning caching off for one test

Override the adapter for the current process only:

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

Every read in that process is a miss and nothing is stored. The override
dies with the process, so no cleanup is needed.

## Writing your own adapter

If you implement `AshCache.Store.Adapter`, the package's own contract test
is a good template: it runs the same `get`, `put`, `del`, `clear` and TTL
checks against every shipped adapter. Copy the pattern and point it at
yours.
