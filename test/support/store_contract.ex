defmodule AshCache.Test.StoreContract do
  @moduledoc """
  Contract shared by every store adapter's test module. Each adapter runs
  the same assertions, so a new adapter cannot drift from the
  `AshCache.Store.Adapter` behaviour.
  """

  @doc "Restores a previously captured `:ash_cache_adapter` process override."
  @spec restore_adapter(module() | nil) :: :ok
  def restore_adapter(nil) do
    Process.delete(:ash_cache_adapter)
    :ok
  end

  def restore_adapter(adapter) do
    Process.put(:ash_cache_adapter, adapter)
    :ok
  end

  @doc "Polls `condition` (yielding between attempts) until true or timeout."
  @spec wait_until((-> boolean()), non_neg_integer()) :: :ok | :timeout
  def wait_until(condition, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(condition, deadline)
  end

  defp poll(condition, deadline) do
    cond do
      condition.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> poll(yield_then(condition), deadline)
    end
  end

  defp yield_then(condition) do
    :erlang.yield()
    condition
  end

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    quote bind_quoted: [adapter: adapter] do
      import AshCache.Test.StoreContract, only: [wait_until: 1]

      @adapter adapter

      test "reading an unknown key is a miss", %{store: store} do
        assert {:ok, nil} = @adapter.get(store, :unknown)
      end

      test "a stored value reads back", %{store: store} do
        assert :ok = @adapter.put(store, :key, "value", [])
        assert {:ok, "value"} = @adapter.get(store, :key)
      end

      test "deleting a key removes its value", %{store: store} do
        :ok = @adapter.put(store, :key, "value", [])
        assert :ok = @adapter.del(store, :key)
        assert {:ok, nil} = @adapter.get(store, :key)
      end

      test "clearing removes every value", %{store: store} do
        :ok = @adapter.put(store, :first, 1, [])
        :ok = @adapter.put(store, :second, 2, [])
        assert :ok = @adapter.clear(store)
        assert {:ok, nil} = @adapter.get(store, :first)
        assert {:ok, nil} = @adapter.get(store, :second)
      end

      test "an expired entry is a miss", %{store: store} do
        :ok = @adapter.put(store, :key, "value", ttl: 1)

        assert :ok = wait_until(fn -> @adapter.get(store, :key) == {:ok, nil} end)
      end

      test "an entry within its ttl still reads back", %{store: store} do
        :ok = @adapter.put(store, :key, "value", ttl: to_timeout(hour: 1))
        assert {:ok, "value"} = @adapter.get(store, :key)
      end

      test "any term works as a key", %{store: store} do
        key = {:ash_cache, SomeResource, 0, :read, [], :no_actor}
        :ok = @adapter.put(store, key, [1, 2], [])
        assert {:ok, [1, 2]} = @adapter.get(store, key)
      end
    end
  end
end
