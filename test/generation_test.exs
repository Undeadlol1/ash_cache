defmodule AshCache.GenerationTest do
  use ExUnit.Case, async: true

  alias AshCache.Generation
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
    def del(_store, _key), do: {:error, :store_down}
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
    def put(_store, {:ash_cache_generation, _}, _value, _opts), do: {:error, :rejected}
    def put(store, key, value, opts), do: ProcessLocal.put(store, key, value, opts)
    @impl true
    defdelegate del(store, key), to: ProcessLocal
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
    def put(_store, {:ash_cache_generation, _}, _value, _opts), do: {:error, :rejected}
    def put(store, key, value, opts), do: ProcessLocal.put(store, key, value, opts)
    @impl true
    def del(_store, {:ash_cache_generation, _}), do: {:error, :rejected}
    def del(store, key), do: ProcessLocal.del(store, key)
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
    {:ok, store: :"generation_store_#{System.unique_integer([:positive])}"}
  end

  test "a missing counter is a value no write ever produced, kept for later reads", %{
    store: store
  } do
    first = Generation.current(store, SomeResource)

    refute first == 0
    assert Generation.current(store, SomeResource) == first
  end

  test "each bump changes the generation to a value never seen before", %{store: store} do
    seen = [Generation.current(store, SomeResource)]

    assert :ok = Generation.bump(store, SomeResource)
    first = Generation.current(store, SomeResource)
    refute first in seen

    assert :ok = Generation.bump(store, SomeResource)
    refute Generation.current(store, SomeResource) in [first | seen]
  end

  test "resources have independent generations", %{store: store} do
    other = Generation.current(store, OtherResource)
    :ok = Generation.bump(store, SomeResource)

    assert Generation.current(store, OtherResource) == other
  end

  describe "a counter the store loses, which must never bring an old generation back" do
    test "after one or more bumps", %{store: store} do
      seen = bump_and_collect(store, 3)
      :ok = AshCache.Store.del(store, counter_key())

      refute Generation.current(store, SomeResource) in seen
    end

    test "when the whole store is cleared", %{store: store} do
      seen = bump_and_collect(store, 2)
      :ok = AshCache.Store.clear(store)

      refute Generation.current(store, SomeResource) in seen
    end

    test "when only the counter is evicted and old entries survive", %{store: store} do
      [old | _] = bump_and_collect(store, 1)
      old_key = {:ash_cache, SomeResource, old, :read}
      :ok = AshCache.Store.put(store, old_key, ["stale"], ttl: :infinity)
      :ok = AshCache.Store.del(store, counter_key())

      new_key = {:ash_cache, SomeResource, Generation.current(store, SomeResource), :read}
      assert {:ok, nil} = AshCache.Store.get(store, new_key)
    end
  end

  defp bump_and_collect(store, count) do
    initial = Generation.current(store, SomeResource)

    Enum.reduce(1..count, [initial], fn _, seen ->
      :ok = Generation.bump(store, SomeResource)
      [Generation.current(store, SomeResource) | seen]
    end)
  end

  defp counter_key, do: {:ash_cache_generation, SomeResource}

  describe "when the store itself is unhealthy" do
    setup do
      use_adapter(UnhealthyStore)
    end

    test "an errored read never answers a generation from before", %{store: store} do
      refute Generation.current(store, SomeResource) == 0
    end

    test "no two errored reads agree, so every pre-error key stays unreachable", %{store: store} do
      refute Generation.current(store, SomeResource) == Generation.current(store, SomeResource)
    end

    test "a bump reports the error", %{store: store} do
      assert {:error, :store_down} = Generation.bump(store, SomeResource)
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
      assert :ok = Generation.bump(store, SomeResource)
      refute Generation.current(store, SomeResource) in seen
    end

    test "a missing counter that cannot be stored is new on every read", %{
      store: store,
      seen: seen
    } do
      :ok = AshCache.Store.del(store, counter_key())
      first = Generation.current(store, SomeResource)

      refute first in seen
      refute Generation.current(store, SomeResource) in [first | seen]
    end
  end

  describe "when the store rejects both writing and deleting the counter" do
    setup do
      use_adapter(CounterWritesAndDeletesFail)
    end

    test "a bump reports the error instead of claiming success", %{store: store} do
      assert {:error, :rejected} = Generation.bump(store, SomeResource)
    end
  end

  describe "readers finding the counter missing, on a store shared between processes" do
    setup do
      store = :"generation_heal_race_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})
      use_adapter(AshCache.Store.Adapters.Cachex)
      {:ok, store: store}
    end

    test "two readers finding it missing at once each land on a new value", %{store: store} do
      seen = bump_and_collect(store, 2)
      :ok = AshCache.Store.del(store, counter_key())

      generations =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Generation.current(store, SomeResource) end) end)
        |> Task.await_many()

      assert Enum.all?(generations, &(&1 not in seen))
      refute Generation.current(store, SomeResource) in seen
    end

    test "lands on a value that is neither the old one nor the bump's", %{store: store} do
      seen = bump_and_collect(store, 1)
      :ok = AshCache.Store.del(store, counter_key())
      owner = self()

      reader =
        Task.async(fn ->
          Process.put(:ash_cache_adapter, AshCache.Test.GatedCounterReadAdapter)
          Process.put(:gate_owner, owner)
          Generation.current(store, SomeResource)
        end)

      assert_receive {:read_counter, _pid, {:ok, nil}}
      :ok = Generation.bump(store, SomeResource)
      bumped = Generation.current(store, SomeResource)
      send(reader.pid, :proceed)
      healed = Task.await(reader)

      refute healed in [bumped | seen]
      assert Generation.current(store, SomeResource) in [healed, bumped]
      refute Generation.current(store, SomeResource) in seen
    end
  end

  describe "against the production Cachex adapter, where a rejected unbounded TTL would silently disable invalidation" do
    setup do
      store = :"generation_cachex_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})

      previous = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous) end)

      {:ok, store: store}
    end

    test "bump succeeds and changes the generation each time", %{store: store} do
      assert :ok = Generation.bump(store, SomeResource)
      first = Generation.current(store, SomeResource)
      refute first == 0

      assert :ok = Generation.bump(store, SomeResource)
      refute Generation.current(store, SomeResource) in [0, first]
    end

    test "the counter outlives ordinary cached entries", %{store: store} do
      :ok = Generation.bump(store, SomeResource)
      :ok = AshCache.Store.put(store, :short_lived, "value", ttl: 1)

      assert :ok =
               StoreContract.wait_until(fn ->
                 AshCache.Store.get(store, :short_lived) == {:ok, nil}
               end)

      refute Generation.current(store, SomeResource) == 0
    end
  end

  describe "two writes committing concurrently" do
    setup do
      store = :"generation_race_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})

      previous = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous) end)

      {:ok, store: store}
    end

    test "never leave the generation a reader could already have cached under", %{store: store} do
      before_either = Generation.current(store, SomeResource)
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
          Generation.bump(store, SomeResource)
        end)

      receive do
        {:read_counter, pid, _value} when pid == task.pid -> {:blocked, task, store}
        {ref, :ok} when ref == task.ref -> {:done, Generation.current(store, SomeResource)}
      end
    end

    defp finish_bump({:done, generation}), do: generation

    defp finish_bump({:blocked, task, store}) do
      send(task.pid, :proceed)
      assert :ok = Task.await(task)
      Generation.current(store, SomeResource)
    end
  end

  describe "surviving the store's capacity bound" do
    setup do
      Process.put(:ash_cache_adapter, ProcessLocal)
      on_exit(fn -> ProcessLocal.clear(:ash_cache) end)
      :ok
    end

    test "the counter survives an overflow of distinct cached query shapes" do
      assert :ok = Generation.bump(:ash_cache, __MODULE__)
      before = Generation.current(:ash_cache, __MODULE__)
      refute before == 0

      overflow_the_bound_with_distinct_query_shapes()

      assert Generation.current(:ash_cache, __MODULE__) == before
    end

    defp overflow_the_bound_with_distinct_query_shapes do
      shapes = ProcessLocal.max_entries_per_store() * 2

      Enum.each(1..shapes, fn n ->
        AshCache.Store.put(:ash_cache, {:query_shape, n}, [n], ttl: to_timeout(hour: 1))
      end)
    end
  end
end
