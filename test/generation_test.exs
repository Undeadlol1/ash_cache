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

  setup do
    {:ok, store: :"generation_store_#{System.unique_integer([:positive])}"}
  end

  test "starts at zero for an unknown resource", %{store: store} do
    assert Generation.current(store, SomeResource) == 0
  end

  test "bump increments the generation", %{store: store} do
    assert :ok = Generation.bump(store, SomeResource)
    assert Generation.current(store, SomeResource) == 1

    assert :ok = Generation.bump(store, SomeResource)
    assert Generation.current(store, SomeResource) == 2
  end

  test "resources have independent generations", %{store: store} do
    :ok = Generation.bump(store, SomeResource)

    assert Generation.current(store, SomeResource) == 1
    assert Generation.current(store, OtherResource) == 0
  end

  test "a lost counter self-heals to zero", %{store: store} do
    :ok = Generation.bump(store, SomeResource)
    :ok = AshCache.Store.clear(store)

    assert Generation.current(store, SomeResource) == 0
  end

  describe "when the store itself is unhealthy, where healing to zero would be a rollback" do
    setup do
      previous = Process.get(:ash_cache_adapter)
      Process.put(:ash_cache_adapter, UnhealthyStore)
      on_exit(fn -> StoreContract.restore_adapter(previous) end)
      :ok
    end

    test "an errored read does not answer zero", %{store: store} do
      refute Generation.current(store, SomeResource) == 0
    end

    test "no two errored reads agree, so every pre-error key stays unreachable", %{store: store} do
      refute Generation.current(store, SomeResource) == Generation.current(store, SomeResource)
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

    test "bump succeeds and increments", %{store: store} do
      assert :ok = Generation.bump(store, SomeResource)
      assert Generation.current(store, SomeResource) == 1

      assert :ok = Generation.bump(store, SomeResource)
      assert Generation.current(store, SomeResource) == 2
    end

    test "the counter outlives ordinary cached entries", %{store: store} do
      :ok = Generation.bump(store, SomeResource)
      :ok = AshCache.Store.put(store, :short_lived, "value", ttl: 1)

      assert :ok =
               StoreContract.wait_until(fn ->
                 AshCache.Store.get(store, :short_lived) == {:ok, nil}
               end)

      assert Generation.current(store, SomeResource) == 1
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
      assert before > 0

      overflow_the_bound_with_distinct_query_shapes()

      assert Generation.current(:ash_cache, __MODULE__) >= before
    end

    defp overflow_the_bound_with_distinct_query_shapes do
      shapes = ProcessLocal.max_entries_per_store() * 2

      Enum.each(1..shapes, fn n ->
        AshCache.Store.put(:ash_cache, {:query_shape, n}, [n], ttl: to_timeout(hour: 1))
      end)
    end
  end
end
