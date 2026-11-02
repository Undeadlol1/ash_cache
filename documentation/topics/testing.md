# How to test with AshCache

This guide shows you how to keep parallel tests from sharing a cache, how
to turn caching off for one test, and how to check that something was
cached.

## Keep parallel tests apart

By default every process on the node shares one cache, so a cached read in
one test can show up in another. Switch the test environment to the
process-local store, which gives each test process its own cache:

```elixir
# config/test.exs
config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal
```

Tests marked `async: true` now cannot see each other's cached data.

## Turn caching off for one test

To make every read in the current test hit the database, switch that
process to the store that saves nothing:

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

## Check that a read was cached

Read once, change the data without going through Ash (for example with a
direct `Repo.update_all`), then read again. A cached read returns the old
value. To compare against the database, read a third time with the cache
skipped:

```elixir
MyApp.Shop.Product
|> Ash.Query.set_context(%{ash_cache: :bypass})
|> Ash.read!()
```

To clear a resource's cache by hand inside a test, call
`AshCache.invalidate(MyApp.Shop.Product)`.

## Test your own store adapter

If you wrote an adapter, copy the package's contract test
(`test/support/store_contract.ex` in the repository). It runs the same
`get`, `put`, `del`, `clear` and expiry checks against every adapter that
ships with the package.
