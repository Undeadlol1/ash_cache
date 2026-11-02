defmodule AshCache.MultiServerTest do
  @moduledoc """
  Three servers sharing one partitioned Nebulex cache: this node and two
  `:peer` nodes. Counters for a resource live on whichever server owns
  their key, so these tests write from one server, read from another, and
  stop the server holding the counter.
  """

  use ExUnit.Case, async: false

  alias AshCache.Generation
  alias AshCache.Store
  alias AshCache.Test.PartitionedCache

  @moduletag :multi_server

  defmodule Resource do
    @moduledoc false
  end

  @counter {:ash_cache_generation, Resource}

  setup_all do
    unless Node.alive?() do
      # Distribution needs the port mapper; starting it twice is harmless.
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = Node.start(:"ash_cache_test_#{System.unique_integer([:positive])}", :shortnames)
      # Cachex stores started before the node had a name answer :nodedown
      # while it has one, so later test files need it gone again.
      on_exit(fn -> Node.stop() end)
    end

    :ok
  end

  setup do
    peers =
      for _ <- 1..2 do
        {:ok, peer, node} = :peer.start_link(%{name: :peer.random_name(), longnames: false})
        :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
        :ok = :erpc.call(node, AshCache.Test.Peer, :start_cache, [])
        {peer, node}
      end

    start_supervised!(PartitionedCache)
    previous = Process.get(:ash_cache_adapter)
    Process.put(:ash_cache_adapter, AshCache.Store.Adapters.Nebulex)

    on_exit(fn ->
      AshCache.Test.StoreContract.restore_adapter(previous)
      Enum.each(peers, fn {peer, _} -> catch_exit(:peer.stop(peer)) end)
    end)

    # Every server must see the same three members, or they disagree on
    # which server owns a key.
    members = Enum.sort([node() | Enum.map(peers, &elem(&1, 1))])

    :ok =
      wait_until(fn ->
        Enum.all?(members, &(Enum.sort(on(&1, PartitionedCache, :nodes, [])) == members))
      end)

    {:ok, peers: peers}
  end

  defp wait_until(condition), do: AshCache.Test.StoreContract.wait_until(condition, 5_000)

  defp on(node, module, fun, args), do: :erpc.call(node, module, fun, args)

  test "a value cached on one server is a hit on the others", %{peers: [{_, a}, {_, b}]} do
    on(a, Store, :put, [PartitionedCache, :key, "value", [ttl: :infinity]])

    assert {:ok, "value"} = Store.get(PartitionedCache, :key)
    assert {:ok, "value"} = on(b, Store, :get, [PartitionedCache, :key])
  end

  test "a write on one server clears cached reads on every server", %{peers: [{_, a}, {_, b}]} do
    here = Generation.current(PartitionedCache, Resource)
    assert on(a, Generation, :current, [PartitionedCache, Resource]) == here

    :ok = on(b, Generation, :bump, [PartitionedCache, Resource])

    refute Generation.current(PartitionedCache, Resource) == here
    refute on(a, Generation, :current, [PartitionedCache, Resource]) == here
  end

  test "the server holding the counter leaving never brings back old entries", %{peers: peers} do
    first = Generation.current(PartitionedCache, Resource)

    seen =
      Enum.reduce(1..3, [first], fn _, seen ->
        :ok = Generation.bump(PartitionedCache, Resource)
        [Generation.current(PartitionedCache, Resource) | seen]
      end)

    counter_node = PartitionedCache.find_node!(@counter)
    [{_, survivor} | _] = Enum.reject(peers, fn {_, node} -> node == counter_node end)

    case Enum.find(peers, fn {_, node} -> node == counter_node end) do
      {peer, _node} -> :peer.stop(peer)
      nil -> stop_supervised!(PartitionedCache)
    end

    :ok = wait_until(fn -> length(on(survivor, PartitionedCache, :nodes, [])) == 2 end)

    refute on(survivor, Generation, :current, [PartitionedCache, Resource]) in seen
  end

  test "two servers bumping at once both land on new values", %{peers: [{_, a}, {_, b}]} do
    before = Generation.current(PartitionedCache, Resource)

    [:ok, :ok] =
      [a, b]
      |> Enum.map(fn node ->
        Task.async(fn -> on(node, Generation, :bump, [PartitionedCache, Resource]) end)
      end)
      |> Task.await_many()

    after_both = Generation.current(PartitionedCache, Resource)
    refute after_both == before
    assert on(a, Generation, :current, [PartitionedCache, Resource]) == after_both
  end
end
