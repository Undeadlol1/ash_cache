defmodule AshCache.TransactionReadTest do
  @moduledoc """
  A read inside a database transaction never joins a shared read: it would
  hold a connection while it waits, and it sees rows no other process may.
  """

  use ExUnit.Case, async: false

  alias AshCache.Store.Adapters.Cachex
  alias AshCache.Test.TransactionalWidget

  setup do
    :mnesia.start()
    previous = Application.get_env(:ash_cache, :rebuild_timeout)
    Application.put_env(:ash_cache, :rebuild_timeout, to_timeout(second: 30))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_cache, :rebuild_timeout, previous),
        else: Application.delete_env(:ash_cache, :rebuild_timeout)
    end)
  end

  defp read_task(probe, opts \\ []) do
    Task.async(fn ->
      Process.put(:ash_cache_adapter, Cachex)

      read = fn ->
        TransactionalWidget |> Ash.Query.for_read(:probed, %{probe: probe}) |> Ash.read()
      end

      if opts[:in_transaction] do
        {:ok, result} = Ash.DataLayer.transaction(TransactionalWidget, read)
        result
      else
        read.()
      end
    end)
  end

  defp next_data_layer_read do
    assert_receive {:data_layer_read, pid}, 1_000
    pid
  end

  defp answer(pid, value),
    do: send(pid, {:answer, {:ok, [%TransactionalWidget{id: Ash.UUID.generate(), value: value}]}})

  test "WHEN regression: a read inside a transaction waited for another process's read of the same key THEN it reads for itself at once" do
    outside = read_task(self())
    outside_reader = next_data_layer_read()

    inside = read_task(self(), in_transaction: true)
    inside_reader = next_data_layer_read()
    answer(inside_reader, 2)
    answer(outside_reader, 1)

    assert {:ok, [%{value: 2}]} = Task.await(inside)
    assert {:ok, [%{value: 1}]} = Task.await(outside)
  end

  test "WHEN regression: a read inside a transaction led a shared read that another process waited on THEN that process reads for itself" do
    inside = read_task(self(), in_transaction: true)
    inside_reader = next_data_layer_read()

    outside = read_task(self())
    outside_reader = next_data_layer_read()
    answer(outside_reader, 1)
    answer(inside_reader, 2)

    assert {:ok, [%{value: 1}]} = Task.await(outside)
    assert {:ok, [%{value: 2}]} = Task.await(inside)
  end
end
