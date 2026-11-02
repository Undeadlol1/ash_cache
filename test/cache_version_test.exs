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

  setup do
    {:ok, store: :"cache_version_store_#{System.unique_integer([:positive])}"}
  end

  test "starts at zero for an unknown resource", %{store: store} do
    assert CacheVersion.current(store, SomeResource) == 0
  end

  test "each bump changes the cache version to a value never seen before", %{store: store} do
    seen_versions = [CacheVersion.current(store, SomeResource)]

    assert :ok = CacheVersion.bump(store, SomeResource)
    first_version = CacheVersion.current(store, SomeResource)
    refute first_version in seen_versions

    assert :ok = CacheVersion.bump(store, SomeResource)
    refute CacheVersion.current(store, SomeResource) in [first_version | seen_versions]
  end

  test "resources have independent cache versions", %{store: store} do
    :ok = CacheVersion.bump(store, SomeResource)

    refute CacheVersion.current(store, SomeResource) == 0
    assert CacheVersion.current(store, OtherResource) == 0
  end

  test "a lost counter self-heals to zero", %{store: store} do
    :ok = CacheVersion.bump(store, SomeResource)
    :ok = AshCache.Store.clear(store)

    assert CacheVersion.current(store, SomeResource) == 0
  end

  describe "when the store itself is unhealthy, where healing to zero would be a rollback" do
    setup do
      previous_adapter = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, UnhealthyStore)
      on_exit(fn -> StoreContract.restore_adapter(previous_adapter) end)
      :ok
    end

    test "an errored read does not answer zero", %{store: store} do
      refute CacheVersion.current(store, SomeResource) == 0
    end

    test "no two errored reads agree, so every pre-error key stays unreachable", %{store: store} do
      refute CacheVersion.current(store, SomeResource) ==
               CacheVersion.current(store, SomeResource)
    end
  end

  describe "against the production Cachex adapter, where a rejected unbounded TTL would silently disable invalidation" do
    setup do
      store = :"cache_version_cachex_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: store, start: {Cachex, :start_link, [store, []]}})

      previous_adapter = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous_adapter) end)

      {:ok, store: store}
    end

    test "bump succeeds and changes the cache version each time", %{store: store} do
      assert :ok = CacheVersion.bump(store, SomeResource)
      first_version = CacheVersion.current(store, SomeResource)
      refute first_version == 0

      assert :ok = CacheVersion.bump(store, SomeResource)
      refute CacheVersion.current(store, SomeResource) in [0, first_version]
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

      previous_adapter = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Cachex)
      on_exit(fn -> StoreContract.restore_adapter(previous_adapter) end)

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
      version_before = CacheVersion.current(:ash_cache, __MODULE__)
      refute version_before == 0

      overflow_the_bound_with_distinct_query_shapes()

      assert CacheVersion.current(:ash_cache, __MODULE__) == version_before
    end

    defp overflow_the_bound_with_distinct_query_shapes do
      shape_count = ProcessLocal.max_entries_per_store() * 2

      Enum.each(1..shape_count, fn n ->
        AshCache.Store.put(:ash_cache, {:query_shape, n}, [n], ttl: to_timeout(hour: 1))
      end)
    end
  end
end
