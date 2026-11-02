# How to test with AshCache

The examples below use this resource and these code interfaces. Swap in
your own.

```elixir
cache do
  read :get_by_sku, ttl: :timer.hours(1)
end
```

```elixir
# in MyApp.Shop
resource MyApp.Shop.Product do
  define :create_product, action: :create
  define :update_product, action: :update
  define :get_product_by_sku, action: :get_by_sku, args: [:sku], get?: true
end
```

## Keep parallel tests apart

Do this first. By default every process on the node shares one cache, so a
result cached in one test can show up in another. The process-local store
gives each process its own cache:

```elixir
# config/test.exs
config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal
```

Tests marked `async: true` can no longer see each other's cached data.

## Check that a read is served from the cache

Call `AshCache.Testing.capture_events/0` in `setup`. From then on, each
cache event your test causes arrives in the test's mailbox as
`{:ash_cache, kind, metadata}`, where `kind` is `:hit`, `:miss` or
`:invalidate`.

```elixir
defmodule MyApp.Shop.ProductCacheTest do
  use MyApp.DataCase, async: true

  setup do
    AshCache.Testing.capture_events()
  end

  test "a SKU lookup is cached" do
    MyApp.Shop.create_product!(%{sku: "A1", name: "Lamp"})

    MyApp.Shop.get_product_by_sku!("A1")
    assert_received {:ash_cache, :miss, %{action: :get_by_sku}}

    MyApp.Shop.get_product_by_sku!("A1")
    assert_received {:ash_cache, :hit, %{action: :get_by_sku}}
  end
end
```

The first read goes to the database (a miss) and caches the result. The
second is answered from the cache (a hit). Other tests running at the same
time cannot send you events.

## Check that a write clears the cache

```elixir
test "updating a product clears the cached lookup" do
  product = MyApp.Shop.create_product!(%{sku: "A1", name: "Lamp"})
  MyApp.Shop.get_product_by_sku!("A1")
  MyApp.Shop.get_product_by_sku!("A1")
  assert_received {:ash_cache, :hit, %{action: :get_by_sku}}

  MyApp.Shop.update_product!(product, %{name: "Desk lamp"})
  assert_received {:ash_cache, :invalidate, %{resource: MyApp.Shop.Product}}

  assert %{name: "Desk lamp"} = MyApp.Shop.get_product_by_sku!("A1")
  assert_received {:ash_cache, :miss, %{action: :get_by_sku}}
end
```

`assert_received` takes the first matching message wherever it is in the
mailbox, so the `:invalidate` sent by `create_product!` at the start does
not get in the way.

## Check that two queries or two users don't share an entry

Each different query, actor and tenant gets its own entry, so the second
read below is a miss, not a hit:

```elixir
test "each user gets their own entry" do
  MyApp.Shop.create_product!(%{sku: "A1", name: "Lamp"})
  alice = MyApp.Accounts.create_user!(%{name: "Alice"})
  bob = MyApp.Accounts.create_user!(%{name: "Bob"})

  MyApp.Shop.get_product_by_sku!("A1", actor: alice)
  MyApp.Shop.get_product_by_sku!("A1", actor: bob)

  assert_received {:ash_cache, :miss, _}
  assert_received {:ash_cache, :miss, _}
  refute_received {:ash_cache, :hit, _}
end
```

For two queries, read two different SKUs instead of using two actors.

Pass the actor when the query is built: through a code interface, as
above, or with `Ash.Query.for_read(query, :get_by_sku, %{sku: "A1"}, actor: alice)`.

## Code that reads in another process

**A Task started by the test** sends its events to the test, so
`assert_received` works for reads made inside it. With the process-local
store, though, the Task has its own empty cache: its first read is a miss
even if the test already cached the same result.

```elixir
test "a read inside a Task is reported to the test" do
  MyApp.Shop.create_product!(%{sku: "A1", name: "Lamp"})

  Task.async(fn -> MyApp.Shop.get_product_by_sku!("A1") end) |> Task.await()

  assert_received {:ash_cache, :miss, %{action: :get_by_sku}}
end
```

**A GenServer, or any process the test did not start with `Task`**, is
different. Its events never reach `capture_events/0`. With the process-local
store it also has its own cache, which the test's writes do not clear, so it
can return data the test has already changed.

The simplest fix is to test the read where it is written: move it into a
plain function, call that function from the GenServer, and test the
function in the test process.

If the test has to go through the GenServer, put it in its own module with
`async: false`, turn caching off for every process while it runs, and start
the GenServer in the test so it does not keep state from earlier tests:

```elixir
defmodule MyApp.PriceWatcherTest do
  use MyApp.DataCase, async: false

  setup do
    adapter = Application.get_env(:ash_cache, :adapter)
    Application.put_env(:ash_cache, :adapter, AshCache.Store.Adapters.Noop)
    on_exit(fn -> Application.put_env(:ash_cache, :adapter, adapter) end)
    :ok
  end

  test "the watcher sees the new price" do
    watcher = start_supervised!(MyApp.PriceWatcher)
    # ...
  end
end
```

Because the test is not `async`, you can also watch the GenServer's cache
events with a plain `:telemetry` handler:

```elixir
test "the watcher reads products" do
  test_pid = self()
  handler_id = make_ref()

  :telemetry.attach_many(
    handler_id,
    [[:ash_cache, :read, :hit], [:ash_cache, :read, :miss]],
    fn [:ash_cache, :read, kind], _measurements, metadata, _config ->
      send(test_pid, {:ash_cache, kind, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach(handler_id) end)

  watcher = start_supervised!(MyApp.PriceWatcher)
  # ... make the watcher read ...
  assert_receive {:ash_cache, :miss, %{action: :get_by_sku}}
end
```

With caching off (the `Noop` store), every read is still reported, as a
miss.

## Turn caching off for one test

To make every read in the current test process go to the database:

```elixir
Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Noop)
```

This only affects the test process. Reads still send `:miss` events.

To skip the cache for a single query, give it the bypass context when you
build it. A bypassed read sends no events.

```elixir
MyApp.Shop.Product
|> Ash.Query.for_read(:get_by_sku, %{sku: "A1"}, context: %{ash_cache: :bypass})
|> Ash.read_one!()
```
