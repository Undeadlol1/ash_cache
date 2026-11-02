defmodule AshCache.StaleDataTest do
  @moduledoc """
  Every way the store can lose, refuse or race the generation counter,
  driven through real reads and writes. Each test ends by proving the read
  returns the value of the last write, never one cached before it.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshCache.Store
  alias AshCache.Test.CachedWidget
  alias AshCache.Test.FailingGetAdapter
  alias AshCache.Test.FailingWriteAdapter
  alias AshCache.Test.StoreContract

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

  @counter {:ash_cache_version, CachedWidget}

  defp create!(value) do
    CachedWidget
    |> Ash.Changeset.for_create(:create, %{name: "w", quantity: value})
    |> Ash.create!()
  end

  defp update!(widget, value) do
    widget
    |> Ash.Changeset.for_update(:update, %{quantity: value})
    |> Ash.update!()
  end

  defp read_value do
    [%{quantity: value}] =
      CachedWidget
      |> Ash.Query.for_read(:get_by_name, %{name: "w"})
      |> Ash.read!()

    value
  end

  # Reads twice, so the second read is answered by the cache when caching works.
  defp cache_value do
    value = read_value()
    ^value = read_value()
  end

  defp use_adapter(adapter) do
    previous = Process.get(:ash_cache_adapter)
    Process.put(:ash_cache_adapter, adapter)
    on_exit(fn -> StoreContract.restore_adapter(previous) end)
  end

  defp cached_keys do
    for {{:ash_cache_entry, :ash_cache, {:ash_cache, CachedWidget, _, _, _, _, _} = key}, _} <-
          Process.get(),
        do: key
  end

  test "counter missing before any write" do
    widget = create!(1)
    :ok = Store.delete(:ash_cache, @counter)
    assert cache_value() == 1

    update!(widget, 2)
    assert read_value() == 2
  end

  test "counter lost after one or more writes, while their entries survive" do
    widget = create!(1)
    assert cache_value() == 1

    Enum.reduce(2..4, widget, fn value, widget ->
      :ok = Store.delete(:ash_cache, @counter)
      assert cache_value() == value - 1

      widget = update!(widget, value)
      :ok = Store.delete(:ash_cache, @counter)
      assert read_value() == value
      widget
    end)
  end

  test "store cleared or restarted" do
    widget = create!(1)
    assert cache_value() == 1
    update!(widget, 2)

    :ok = Store.clear(:ash_cache)
    assert read_value() == 2
  end

  test "a reader that cached old rows after the write's bump is never served" do
    widget = create!(1)
    assert cache_value() == 1
    [old_key] = cached_keys()

    update!(widget, 2)
    # The racing reader read before the commit and stores its rows late.
    {:ok, old_rows} = Store.get(:ash_cache, old_key)
    :ok = Store.put(:ash_cache, old_key, old_rows, ttl: :infinity)

    assert read_value() == 2
  end

  test "AshCache.invalidate/1 makes the next read go to the data layer" do
    widget = create!(1)
    update!(widget, 2)
    assert cache_value() == 2

    # Make the cache disagree with the data layer, as a change made outside
    # Ash would.
    [key] = cached_keys()
    {:ok, [row]} = Store.get(:ash_cache, key)
    :ok = Store.put(:ash_cache, key, [%{row | quantity: 1}], ttl: :infinity)
    assert read_value() == 1

    :ok = AshCache.invalidate(CachedWidget)
    assert read_value() == 2
  end

  test "store errors on every read: nothing is cached, every read is fresh" do
    widget = create!(1)
    use_adapter(FailingGetAdapter)

    assert read_value() == 1
    update!(widget, 2)
    assert read_value() == 2
  end

  test "store errors on every write: nothing is cached, every read is fresh" do
    use_adapter(FailingWriteAdapter)

    capture_log(fn ->
      widget = create!(1)
      assert cache_value() == 1
      update!(widget, 2)
      assert read_value() == 2
    end)
  end

  test "a bump the store refuses deletes the counter instead" do
    widget = create!(1)
    assert cache_value() == 1
    use_adapter(CounterWritesFail)

    update!(widget, 2)
    assert read_value() == 2
    assert read_value() == 2
  end

  test "a bump the store refuses entirely is logged as a warning" do
    widget = create!(1)
    use_adapter(FailingWriteAdapter)

    assert capture_log(fn -> update!(widget, 2) end) =~
             "AshCache could not invalidate AshCache.Test.CachedWidget: :boom"
  end
end
