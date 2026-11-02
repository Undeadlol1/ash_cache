defmodule AshCache.CacheVersionTest do
  use ExUnit.Case, async: true

  alias AshCache.CacheVersion
  alias AshCache.Store.Adapters.ProcessLocal
  alias AshCache.Test.StoreContract

  defmodule SomeResource do
    @moduledoc false
  end

  defmodule OtherResource do
    @moduledoc false
  end

  defmodule UnhealthyStore do
    @moduledoc false
    @behaviour AshCache.Store.Adapter

    @impl true
    def get(_store, _key), do: {:error, :store_down}
    @impl true
    def put(_store, _key, _value, _opts), do: {:error, :store_down}
    @impl true
    def delete(_store, _key), do: {:error, :store_down}
    @impl true
    def clear(_store), do: {:error, :store_down}
  end

  defmodule CounterWritesFail do
    @moduledoc false
    @behaviour AshCache.Store.Adapter

    alias AshCache.Store.Adapters.ProcessLocal

    @impl true
    defdelegate get(store, key), to: ProcessLocal
    @impl true
    def put(_store, {:ash_cache_version, _}, _value, _opts), do: {:error, :rejected}
    def put(store, key, value, opts), do: ProcessLocal.put(store, key, value, opts)
    @impl true
    defdelegate delete(store, key), to: ProcessLocal
    @impl true
    defdelegate clear(store), to: ProcessLocal
  end

  defmodule CounterWritesAndDeletesFail do
    @moduledoc false
    @behaviour AshCache.Store.Adapter

    alias AshCache.Store.Adapters.ProcessLocal

    @impl true
    defdelegate get(store, key), to: ProcessLocal
    @impl true
    def put(_store, {:ash_cache_version, _}, _value, _opts), do: {:error, :rejected}
    def put(store, key, value, opts), do: ProcessLocal.put(store, key, value, opts)
    @impl true
    def delete(_store, {:ash_cache_version, _}), do: {:error, :rejected}
    def delete(store, key), do: ProcessLocal.delete(store, key)
    @impl true
    defdelegate clear(store), to: ProcessLocal
  end

  defp use_adapter(adapter) do
    previous = Process.get(:ash_cache_adapter)
    Process.put(:ash_cache_adapter, adapter)
    on_exit(fn -> StoreContract.restore_adapter(previous) end)
    :ok
  end

  setup do
    {:ok, store: :"cache_version_store_#{System.unique_integer([:positive])}"}
  end

  test "a missing counter is a value no write ever produced, kept for later reads", %{
    store: store
  } do
    first = CacheVersion.current(store, SomeResource)

    refute first == 0
    assert CacheVersion.current(store, SomeResource) == first
  end

  test "each bump changes the cache version to a value never seen before", %{store: store} do
    seen = [CacheVersion.current(store, SomeResource)]

    assert :ok = CacheVersion.bump(store, SomeResource)
    first = CacheVersion.current(store, SomeResource)
    refute first in seen

    assert :ok = CacheVersion.bump(store, SomeResource)
    refute CacheVersion.current(store, SomeResource) in [first | seen]
  end

  test "resources have independent cache versions", %{store: store} do
    other = CacheVersion.current(store, OtherResource)
    :ok = CacheVersion.bump(store, SomeResource)

    assert CacheVersion.current(store, OtherResource) == other
  end

  describe "a counter the store loses, which must never bring an old cache version back" do
    test "after one or more bumps", %{store: store} do
      seen = bump_and_collect(store, 3)
      :ok = AshCache.Store.delete(store, counter_key())

      refute CacheVersion.current(store, SomeResource) in seen
    end

    test "when the whole store is cleared", %{store: store} do
      seen = bump_and_collect(store, 2)
      :ok = AshCache.Store.clear(store)

      refute CacheVersion.current(store, SomeResource) in seen
    end

    test "when only the counter is evicted and old entries survive", %{store: store} do
      [old | _] = bump_and_collect(store, 1)
      old_key = {:ash_cache, SomeResource, old, :read}
      :ok = AshCache.Store.put(store, old_key, ["stale"], ttl: :infinity)
      :ok = AshCache.Store.delete(store, counter_key())

      new_key = {:ash_cache, SomeResource, CacheVersion.current(store, SomeResource), :read}
      assert {:ok, nil} = AshCache.Store.get(store, new_key)
    end
  end

  defp bump_and_collect(store, count) do
    initial = CacheVersion.current(store, SomeResource)

    Enum.reduce(1..count, [initial], fn _, seen ->
      :ok = CacheVersion.bump(store, SomeResource)
      [CacheVersion.current(store, SomeResource) | seen]
    end)
  end

  defp counter_key, do: {:ash_cache_version, SomeResource}

  describe "when the store itself is unhealthy" do
    setup do
      use_adapter(UnhealthyStore)
    end

    test "an errored read never answers a cache version from before", %{store: store} do
      refute CacheVersion.current(store, SomeResource) == 0
    end

    test "no two errored reads agree, so every pre-error key stays unreachable", %{store: store} do
      refute CacheVersion.current(store, SomeResource) ==
               CacheVersion.current(store, SomeResource)
    end

    test "a bump reports the error", %{store: store} do
      assert {:error, :store_down} = CacheVersion.bump(store, SomeResource)
    end
  end

  describe "when the store reads fine but rejects writes of the counter" do
    setup %{store: store} do
      seen = bump_and_collect(store, 2)
      use_adapter(CounterWritesFail)
      {:ok, seen: seen}
    end

    test "a failed bump deletes the counter, so the next read lands on a new value", %{
      store: store,
      seen: seen
    } do
      assert :ok = CacheVersion.bump(store, SomeResource)
      refute CacheVersion.current(store, SomeResource) in seen
    end

    test "a missing counter that cannot be stored is new on every read", %{
      store: store,
      seen: seen
    } do
      :ok = AshCache.Store.delete(store, counter_key())
      first = CacheVersion.current(store, SomeResource)

      refute first in seen
      refute CacheVersion.current(store, SomeResource) in [first | seen]
    end
  end

  describe "when the store rejects both writing and deleting the counter" do
    setup do
      use_adapter(CounterWritesAndDeletesFail)
    end

    test "a bump reports the error instead of claiming success", %{store: store} do
      assert {:error, :rejected} = CacheVersion.bump(store, SomeResource)
    end
  end

  describe "readers finding the counter missing, on a store shared between processes" do
    setup do
      store = :"cache_version_heal_race_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})
      use_adapter(AshCache.Store.Adapters.Cachex)
      {:ok, store: store}
    end

    test "two readers finding it missing at once each land on a new value", %{store: store} do
      seen = bump_and_collect(store, 2)
      :ok = AshCache.Store.delete(store, counter_key())

      versions =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> CacheVersion.current(store, SomeResource) end) end)
        |> Task.await_many()

      assert Enum.all?(versions, &(&1 not in seen))
      refute CacheVersion.current(store, SomeResource) in seen
    end

    test "lands on the bump's value or a new one, never an old one", %{store: store} do
      seen = bump_and_collect(store, 1)
      :ok = AshCache.Store.delete(store, counter_key())
      owner = self()

      reader =
        Task.async(fn ->
          Process.put(:ash_cache_adapter, AshCache.Test.GatedCounterReadAdapter)
          Process.put(:gate_owner, owner)
          CacheVersion.current(store, SomeResource)
        end)

      assert_receive {:read_counter, _pid, {:ok, nil}}
      :ok = CacheVersion.bump(store, SomeResource)
      bumped = CacheVersion.current(store, SomeResource)
      # Twice: the reader looks at the counter again once it leads the
      # replacement.
      send(reader.pid, :proceed)
      send(reader.pid, :proceed)
      healed = Task.await(reader)

      # Adopting the bump's value is fine: this reader reads the data layer
      # after the write committed.
      refute healed in seen
      assert CacheVersion.current(store, SomeResource) in [healed, bumped]
      refute CacheVersion.current(store, SomeResource) in seen
    end
  end

  describe "against the production Cachex adapter, where a rejected unbounded TTL would silently disable invalidation" do
    setup do
      store = :"cache_version_cachex_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})

      previous = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous) end)

      {:ok, store: store}
    end

    test "bump succeeds and changes the cache version each time", %{store: store} do
      assert :ok = CacheVersion.bump(store, SomeResource)
      first = CacheVersion.current(store, SomeResource)
      refute first == 0

      assert :ok = CacheVersion.bump(store, SomeResource)
      refute CacheVersion.current(store, SomeResource) in [0, first]
    end

    test "the counter outlives ordinary cached entries", %{store: store} do
      :ok = CacheVersion.bump(store, SomeResource)
      :ok = AshCache.Store.put(store, :short_lived, "value", ttl: 1)

      assert :ok =
               StoreContract.wait_until(fn ->
                 AshCache.Store.get(store, :short_lived) == {:ok, nil}
               end)

      refute CacheVersion.current(store, SomeResource) == 0
    end
  end

  describe "two writes committing concurrently" do
    setup do
      store = :"cache_version_race_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})

      previous = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous) end)

      {:ok, store: store}
    end

    test "never leave the cache version a reader could already have cached under", %{store: store} do
      before_either = CacheVersion.current(store, SomeResource)
      first = start_bump(store)
      second = start_bump(store)

      after_first = finish_bump(first)
      after_both = finish_bump(second)

      refute after_first == before_either
      refute after_both == before_either
      refute after_both == after_first
    end

    defp start_bump(store) do
      owner = self()

      task =
        Task.async(fn ->
          Process.put(:ash_cache_adapter, AshCache.Test.GatedCounterReadAdapter)
          Process.put(:gate_owner, owner)
          CacheVersion.bump(store, SomeResource)
        end)

      receive do
        {:read_counter, pid, _value} when pid == task.pid -> {:blocked, task, store}
        {ref, :ok} when ref == task.ref -> {:done, CacheVersion.current(store, SomeResource)}
      end
    end

    defp finish_bump({:done, version}), do: version

    defp finish_bump({:blocked, task, store}) do
      send(task.pid, :proceed)
      assert :ok = Task.await(task)
      CacheVersion.current(store, SomeResource)
    end
  end

  describe "surviving the store's capacity bound" do
    setup do
      Process.put(:ash_cache_adapter, ProcessLocal)
      on_exit(fn -> ProcessLocal.clear(:ash_cache) end)
      :ok
    end

    test "the counter survives an overflow of distinct cached query shapes" do
      assert :ok = CacheVersion.bump(:ash_cache, __MODULE__)
      before = CacheVersion.current(:ash_cache, __MODULE__)
      refute before == 0

      overflow_the_bound_with_distinct_query_shapes()

      assert CacheVersion.current(:ash_cache, __MODULE__) == before
    end

    defp overflow_the_bound_with_distinct_query_shapes do
      shapes = ProcessLocal.max_entries_per_store() * 2

      Enum.each(1..shapes, fn n ->
        AshCache.Store.put(:ash_cache, {:query_shape, n}, [n], ttl: to_timeout(hour: 1))
      end)
    end
  end
end
