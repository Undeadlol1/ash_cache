defmodule AshCache.StampedeTest do
  @moduledoc """
  Many identical reads missing at once: only one goes to the data layer and
  the rest share its result. The reads run in tasks against the suite's
  shared Cachex store, as requests on one server would.
  """

  # Counts every request waiting for a rebuild on this server.
  use ExUnit.Case, async: false

  alias AshCache.Store.Adapters.Cachex
  alias AshCache.Test.Events
  alias AshCache.Test.ProbedWidget

  @readers 50

  setup do
    AshCache.Testing.capture_events()
  end

  # The reads run in tasks, but report to the test: the probe is the test.
  defp start_reads(count, opts \\ []) do
    test = self()

    for _ <- 1..count do
      Task.async(fn ->
        Process.put(:ash_cache_adapter, Cachex)

        ProbedWidget
        |> Ash.Query.for_read(:probed, %{probe: test}, Keyword.take(opts, [:context]))
        |> Ash.read(Keyword.drop(opts, [:context]))
      end)
    end
  end

  defp next_data_layer_read do
    assert_receive {:data_layer_read, pid}, 2_000
    pid
  end

  defp answer(pid, value),
    do: send(pid, {:answer, {:ok, [%ProbedWidget{id: Ash.UUID.generate(), value: value}]}})

  defp waiting(count) do
    :ok =
      AshCache.Test.StoreContract.wait_until(
        fn -> Registry.count(AshCache.Coalesce.Waiters) == count end,
        2_000
      )
  end

  test "many identical misses make one data-layer read and all get its result" do
    tasks = start_reads(@readers)

    leader = next_data_layer_read()
    waiting(@readers - 1)
    answer(leader, 1)

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, [%{value: 1}]}, &1))
    refute_receive {:data_layer_read, _}, 100
    assert Enum.frequencies(Events.drain()) == %{miss: 1, hit: @readers - 1}
  end

  test "a failed rebuild: its reader gets the error, one waiter rebuilds for the rest" do
    tasks = start_reads(@readers)

    leader = next_data_layer_read()
    waiting(@readers - 1)
    send(leader, {:answer, {:error, :database_down}})

    second = next_data_layer_read()
    answer(second, 2)

    results = Task.await_many(tasks)
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert Enum.count(results, &match?({:ok, [%{value: 2}]}, &1)) == @readers - 1
    refute_receive {:data_layer_read, _}, 100
  end

  test "a rebuild whose process dies: one waiter rebuilds for the rest" do
    tasks = start_reads(@readers)

    leader = next_data_layer_read()
    waiting(@readers - 1)
    Process.unlink(leader)
    Process.exit(leader, :kill)

    answer(next_data_layer_read(), 3)

    results = tasks |> Enum.reject(&(&1.pid == leader)) |> Task.await_many()
    assert Enum.all?(results, &match?({:ok, [%{value: 3}]}, &1))
    refute_receive {:data_layer_read, _}, 100
  end

  test "a rebuild slower than the wait limit: waiters read for themselves" do
    previous = Application.get_env(:ash_cache, :rebuild_timeout)
    Application.put_env(:ash_cache, :rebuild_timeout, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_cache, :rebuild_timeout, previous),
        else: Application.delete_env(:ash_cache, :rebuild_timeout)
    end)

    tasks = start_reads(3)
    leader = next_data_layer_read()

    others = [next_data_layer_read(), next_data_layer_read()]
    Enum.each([leader | others], &answer(&1, 4))

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, [%{value: 4}]}, &1))
  end

  test "different actors never share a rebuild" do
    tasks =
      for actor <- [%{id: 1}, %{id: 2}], _ <- 1..5 do
        test = self()

        Task.async(fn ->
          Process.put(:ash_cache_adapter, Cachex)

          ProbedWidget
          |> Ash.Query.for_read(:probed, %{probe: test}, actor: actor)
          |> Ash.read(actor: actor)
        end)
      end

    first = next_data_layer_read()
    second = next_data_layer_read()
    answer(first, 5)
    answer(second, 5)

    assert length(Task.await_many(tasks)) == 10
    refute_receive {:data_layer_read, _}, 100
  end

  test "different tenants never share a rebuild" do
    tasks = start_reads(5, tenant: "acme") ++ start_reads(5, tenant: "globex")

    answer(next_data_layer_read(), 6)
    answer(next_data_layer_read(), 6)

    assert length(Task.await_many(tasks)) == 10
    refute_receive {:data_layer_read, _}, 100
  end

  test "bypassed reads each go to the data layer and wait for nobody" do
    tasks = start_reads(3, context: %{ash_cache: :bypass})

    Enum.each(1..3, fn _ -> answer(next_data_layer_read(), 7) end)

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, [%{value: 7}]}, &1))
    assert Events.drain() == []
  end

  test "readers finding the version value missing share one new value and one read" do
    Process.put(:ash_cache_adapter, Cachex)
    :ok = AshCache.Store.delete(:ash_cache, {:ash_cache_version, ProbedWidget})
    tasks = start_reads(@readers)

    leader = next_data_layer_read()
    waiting(@readers - 1)
    answer(leader, 9)

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, [%{value: 9}]}, &1))
    refute_receive {:data_layer_read, _}, 100
  end

  test "a read on its own is unaffected" do
    [task] = start_reads(1)
    answer(next_data_layer_read(), 8)
    assert {:ok, [%{value: 8}]} = Task.await(task)
  end
end
