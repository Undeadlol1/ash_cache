defmodule AshCache.RememberTest do
  @moduledoc """
  `AshCache.remember/4`: a small derived value kept in the resource's store,
  with no Ash read in the way of a hit.
  """

  use ExUnit.Case, async: false

  alias AshCache.Store.Adapters.Cachex
  alias AshCache.Store.Adapters.Noop
  alias AshCache.Store.Adapters.Nebulex
  alias AshCache.Test.BlockTtlWidget
  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Comment
  alias AshCache.Test.DefaultTtlWidget
  alias AshCache.Test.Events
  alias AshCache.Test.FailingGetAdapter
  alias AshCache.Test.FailingWriteAdapter
  alias AshCache.Test.InfiniteBlockWidget
  alias AshCache.Test.NebulexCache
  alias AshCache.Test.NebulexWidget
  alias AshCache.Test.Part
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Post
  alias AshCache.Test.StoreContract
  alias AshCache.Test.Widget

  setup do
    AshCache.Testing.capture_events()
  end

  defp loader(value) do
    test = self()

    fn ->
      send(test, :loader_ran)
      {:ok, value}
    end
  end

  defp loads do
    receive do
      :loader_ran -> 1 + loads()
    after
      0 -> 0
    end
  end

  defp create!(resource, name \\ "w") do
    resource
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  defp use_adapter(adapter) do
    previous = Process.get(:ash_cache_adapter)
    Process.put(:ash_cache_adapter, adapter)
    on_exit(fn -> StoreContract.restore_adapter(previous) end)
  end

  defp remembered_expiries(resource) do
    for {{:ash_cache_entry, _store, {:ash_cache_remembered, ^resource, _version, _key}},
         {_value, expires_at}} <- Process.get(),
        do: expires_at
  end

  defp assert_expires_in(expires_at, ttl_ms, window) do
    {before_ms, after_ms} = window
    assert expires_at in (before_ms + ttl_ms)..(after_ms + ttl_ms)
  end

  defp timed(fun) do
    before_ms = System.monotonic_time(:millisecond)
    result = fun.()
    {result, {before_ms, System.monotonic_time(:millisecond)}}
  end

  describe "remembering" do
    test "the first call runs the loader and the second is answered from the store" do
      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert AshCache.remember(CachedWidget, :flag, loader(:other)) == {:ok, :on}

      assert loads() == 1
    end

    test "falsy and empty values are remembered, not reloaded" do
      for value <- [nil, false, [], %{}, "", 0] do
        key = {:falsy, value}
        assert AshCache.remember(CachedWidget, key, loader(value)) == {:ok, value}
        assert AshCache.remember(CachedWidget, key, loader(:reloaded)) == {:ok, value}
      end

      assert loads() == 6
    end

    test "an error is returned and not remembered" do
      failing = fn ->
        send(self(), :loader_ran)
        {:error, :service_down}
      end

      assert AshCache.remember(CachedWidget, :flag, failing) == {:error, :service_down}
      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}

      assert loads() == 2
    end

    test "a raising loader propagates and remembers nothing" do
      assert_raise RuntimeError, "boom", fn ->
        AshCache.remember(CachedWidget, :flag, fn -> raise "boom" end)
      end

      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert loads() == 1
    end

    test "different keys, and different resources, hold different values" do
      assert AshCache.remember(CachedWidget, {:user, 1}, loader(:a)) == {:ok, :a}
      assert AshCache.remember(CachedWidget, {:user, 2}, loader(:b)) == {:ok, :b}
      assert AshCache.remember(Post, {:user, 1}, loader(:c)) == {:ok, :c}

      assert AshCache.remember(CachedWidget, {:user, 1}, loader(:x)) == {:ok, :a}
      assert AshCache.remember(CachedWidget, {:user, 2}, loader(:x)) == {:ok, :b}
      assert AshCache.remember(Post, {:user, 1}, loader(:x)) == {:ok, :c}
    end

    test "a key equal to a cached action's name never meets a cached read" do
      create!(CachedWidget)
      before_read = Ash.read!(CachedWidget)

      assert AshCache.remember(CachedWidget, :read, loader(:mine)) == {:ok, :mine}

      assert Ash.read!(CachedWidget) == before_read
      assert AshCache.remember(CachedWidget, :read, loader(:x)) == {:ok, :mine}
    end

    test "a resource without the extension raises a clear error" do
      assert_raise ArgumentError, ~r/AshCache\.Resource/, fn ->
        AshCache.remember(Widget, :flag, loader(:on))
      end

      assert_raise ArgumentError, ~r/AshCache\.Resource/, fn ->
        AshCache.forget(Widget, :flag)
      end
    end
  end

  describe "a hit does no Ash work" do
    setup do
      Code.ensure_loaded!(Ash.Actions.Read)
      Code.ensure_loaded!(Ash.Query)
      Code.ensure_loaded!(Ash.Policy.Authorizer)

      :erlang.trace_pattern({Ash.Actions.Read, :_, :_}, true, [:local])
      :erlang.trace_pattern({Ash.Query, :for_read, :_}, true, [:local])
      :erlang.trace_pattern({Ash.Policy.Authorizer, :_, :_}, true, [:local])
      :erlang.trace(self(), true, [:call, {:tracer, ash_call_reporter(self())}])

      on_exit(fn ->
        :erlang.trace_pattern({Ash.Actions.Read, :_, :_}, false, [:local])
        :erlang.trace_pattern({Ash.Query, :for_read, :_}, false, [:local])
        :erlang.trace_pattern({Ash.Policy.Authorizer, :_, :_}, false, [:local])
      end)
    end

    test "the tracer sees an Ash read when one runs" do
      Ash.read!(CachedWidget)

      assert_receive {:ash_called, Ash.Actions.Read, _function}
    end

    test "a warm hit runs no Ash action and never calls the loader" do
      AshCache.remember(CachedWidget, :flag, loader(:on))
      assert loads() == 1

      for _ <- 1..3,
          do: assert(AshCache.remember(CachedWidget, :flag, loader(:off)) == {:ok, :on})

      assert loads() == 0
      refute_receive {:ash_called, _module, _function}, 50
    end

    defp ash_call_reporter(test) do
      spawn(fn -> report_ash_calls(test) end)
    end

    defp report_ash_calls(test) do
      receive do
        {:trace, _pid, :call, {module, function, _args}} ->
          send(test, {:ash_called, module, function})
          report_ash_calls(test)
      end
    end
  end

  describe "a write to the resource forgets remembered values" do
    test "create" do
      AshCache.remember(CachedWidget, :flag, loader(:old))

      create!(CachedWidget)

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end

    test "update" do
      widget = create!(CachedWidget)
      AshCache.remember(CachedWidget, :flag, loader(:old))

      widget |> Ash.Changeset.for_update(:update, %{quantity: 2}) |> Ash.update!()

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end

    test "destroy" do
      widget = create!(CachedWidget)
      AshCache.remember(CachedWidget, :flag, loader(:old))

      Ash.destroy!(widget)

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end

    test "a failed write leaves them" do
      widget = create!(CachedWidget)
      AshCache.remember(CachedWidget, :flag, loader(:old))

      assert {:error, _invalid} =
               widget |> Ash.Changeset.for_update(:update, %{name: nil}) |> Ash.update()

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :old}
    end

    test "a write to a resource in clear_when_changed" do
      AshCache.remember(Post, :flag, loader(:old))

      create!(Comment)

      assert AshCache.remember(Post, :flag, loader(:new)) == {:ok, :new}
    end

    test "a write to another resource Part is listed by" do
      AshCache.remember(CachedWidget, :flag, loader(:old))

      Part
      |> Ash.Changeset.for_create(:create, %{widget_id: Ash.UUID.generate()})
      |> Ash.create!()

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end

    test "a write to an unrelated resource leaves them" do
      AshCache.remember(Post, :flag, loader(:old))

      create!(CachedWidget)

      assert AshCache.remember(Post, :flag, loader(:new)) == {:ok, :old}
    end

    test "AshCache.invalidate/1" do
      AshCache.remember(CachedWidget, :flag, loader(:old))

      :ok = AshCache.invalidate(CachedWidget)

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end
  end

  describe "forget" do
    test "drops one remembered value and keeps the others" do
      AshCache.remember(CachedWidget, :one, loader(1))
      AshCache.remember(CachedWidget, :two, loader(2))

      assert AshCache.forget(CachedWidget, :one) == :ok

      assert AshCache.remember(CachedWidget, :one, loader(10)) == {:ok, 10}
      assert AshCache.remember(CachedWidget, :two, loader(20)) == {:ok, 2}
    end

    test "a key never remembered is still :ok" do
      assert AshCache.forget(CachedWidget, :never_seen) == :ok
    end
  end

  describe "ttl" do
    test "defaults to the cache block's ttl" do
      {_, window} = timed(fn -> AshCache.remember(DefaultTtlWidget, :flag, loader(1)) end)
      assert [expires_at] = remembered_expiries(DefaultTtlWidget)
      assert_expires_in(expires_at, to_timeout(minute: 5), window)

      {_, window} = timed(fn -> AshCache.remember(BlockTtlWidget, :flag, loader(1)) end)
      assert [expires_at] = remembered_expiries(BlockTtlWidget)
      assert_expires_in(expires_at, to_timeout(minute: 2), window)
    end

    test "an :infinity block ttl never expires" do
      AshCache.remember(InfiniteBlockWidget, :flag, loader(1))

      assert remembered_expiries(InfiniteBlockWidget) == [:infinity]
    end

    test "the ttl option wins over the block's, and :infinity is allowed" do
      {_, window} =
        timed(fn ->
          AshCache.remember(DefaultTtlWidget, :flag, loader(1), ttl: to_timeout(second: 30))
        end)

      assert [expires_at] = remembered_expiries(DefaultTtlWidget)
      assert_expires_in(expires_at, to_timeout(second: 30), window)

      AshCache.remember(BlockTtlWidget, :flag, loader(1), ttl: :infinity)
      assert remembered_expiries(BlockTtlWidget) == [:infinity]
    end

    test "a value past its ttl is loaded again" do
      AshCache.remember(CachedWidget, :flag, loader(:old), ttl: 1)
      [expires_at] = remembered_expiries(CachedWidget)

      assert :ok =
               StoreContract.wait_until(fn ->
                 System.monotonic_time(:millisecond) >= expires_at
               end)

      assert AshCache.remember(CachedWidget, :flag, loader(:new)) == {:ok, :new}
    end
  end

  describe "telemetry" do
    test "the first call is a miss and the second a hit, with resource, store and key" do
      AshCache.remember(CachedWidget, {:user, 1}, loader(:on))

      assert_received {:ash_cache, :miss, %{resource: CachedWidget, store: :ash_cache} = miss}
      assert miss == %{resource: CachedWidget, store: :ash_cache, key: {:user, 1}}

      AshCache.remember(CachedWidget, {:user, 1}, loader(:on))

      assert_received {:ash_cache, :hit, hit}
      assert hit == %{resource: CachedWidget, store: :ash_cache, key: {:user, 1}}
      refute_received {:ash_cache, _kind, _metadata}
    end

    test "the store is the resource's own" do
      AshCache.remember(PartiallyCachedWidget, :flag, loader(:on))

      assert_received {:ash_cache, :miss, %{store: :partial_store}}
    end

    test "events are emitted on the remember event names" do
      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        [[:ash_cache, :remember, :hit], [:ash_cache, :remember, :miss]],
        fn event, _measurements, _metadata, _config -> send(test, {:event, event}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      AshCache.remember(CachedWidget, :flag, loader(:on))
      AshCache.remember(CachedWidget, :flag, loader(:on))

      assert_received {:event, [:ash_cache, :remember, :miss]}
      assert_received {:event, [:ash_cache, :remember, :hit]}
    end

    test "a failed lookup is a miss" do
      use_adapter(FailingGetAdapter)

      AshCache.remember(CachedWidget, :flag, loader(:on))

      assert_received {:ash_cache, :miss, %{resource: CachedWidget}}
      refute_received {:ash_cache, :hit, _}
    end

    test "an error from the loader is a miss and nothing else" do
      AshCache.remember(CachedWidget, :flag, fn -> {:error, :down} end)

      assert Events.drain() == [:miss]
    end
  end

  describe "a failing store" do
    test "a get that fails runs the loader and returns its answer, every time" do
      use_adapter(FailingGetAdapter)

      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert loads() == 2
    end

    test "a put that fails still returns the loader's answer" do
      use_adapter(FailingWriteAdapter)

      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert loads() == 2
    end
  end

  describe "adapters" do
    test "the Noop adapter loads every time" do
      use_adapter(Noop)

      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert AshCache.remember(CachedWidget, :flag, loader(:on)) == {:ok, :on}
      assert loads() == 2
    end

    test "the Cachex adapter remembers, and a write forgets" do
      use_adapter(Cachex)
      key = {:cachex, make_ref()}

      assert AshCache.remember(CachedWidget, key, loader(:old)) == {:ok, :old}
      assert AshCache.remember(CachedWidget, key, loader(:x)) == {:ok, :old}

      create!(CachedWidget)

      assert AshCache.remember(CachedWidget, key, loader(:new)) == {:ok, :new}
      assert AshCache.forget(CachedWidget, key) == :ok
      assert AshCache.remember(CachedWidget, key, loader(:newer)) == {:ok, :newer}
    end

    test "the Nebulex adapter remembers, and a write forgets" do
      start_supervised!(NebulexCache)
      use_adapter(Nebulex)

      assert AshCache.remember(NebulexWidget, :flag, loader(:old)) == {:ok, :old}
      assert AshCache.remember(NebulexWidget, :flag, loader(:x)) == {:ok, :old}

      create!(NebulexWidget)

      assert AshCache.remember(NebulexWidget, :flag, loader(:new)) == {:ok, :new}
    end
  end

  describe "isolation between tests" do
    test "a remembered value is private to the process, as a cached read is" do
      AshCache.remember(CachedWidget, :flag, loader(:mine))

      other =
        Task.async(fn ->
          AshCache.remember(CachedWidget, :flag, fn -> {:ok, :theirs} end)
        end)

      assert Task.await(other) == {:ok, :theirs}
      assert AshCache.remember(CachedWidget, :flag, loader(:x)) == {:ok, :mine}
    end

    test "events from an unrelated process are not delivered" do
      test = self()

      spawn(fn ->
        AshCache.remember(CachedWidget, :flag, fn -> {:ok, 1} end)
        send(test, :done)
      end)

      assert_receive :done, 2000
      refute_received {:ash_cache, _kind, _metadata}
    end
  end

  describe "identical misses at once" do
    @callers 10

    test "share one loader run, and the rest get its answer" do
      test = self()
      key = {:stampede, make_ref()}

      tasks =
        for _ <- 1..@callers do
          Task.async(fn ->
            Process.put(:ash_cache_adapter, Cachex)

            AshCache.remember(CachedWidget, key, fn ->
              send(test, {:loading, self()})

              receive do
                :go -> {:ok, :loaded}
              end
            end)
          end)
        end

      assert_receive {:loading, leader}, 2_000

      :ok =
        StoreContract.wait_until(
          fn -> Registry.count(AshCache.Coalesce.Waiters) == @callers - 1 end,
          2_000
        )

      send(leader, :go)

      assert Task.await_many(tasks) == List.duplicate({:ok, :loaded}, @callers)
      refute_receive {:loading, _}, 100
    end

    test "a raising leader lets a waiter load for itself" do
      test = self()
      key = {:stampede, make_ref()}

      leader =
        Task.async(fn ->
          Process.put(:ash_cache_adapter, Cachex)

          try do
            AshCache.remember(CachedWidget, key, fn ->
              send(test, {:loading, self()})

              receive do
                :go -> raise "boom"
              end
            end)
          rescue
            error -> {:raised, Exception.message(error)}
          end
        end)

      assert_receive {:loading, leader_pid}, 2_000

      waiter =
        Task.async(fn ->
          Process.put(:ash_cache_adapter, Cachex)
          AshCache.remember(CachedWidget, key, fn -> {:ok, :recovered} end)
        end)

      :ok =
        StoreContract.wait_until(fn -> Registry.count(AshCache.Coalesce.Waiters) == 1 end, 2_000)

      send(leader_pid, :go)

      assert Task.await(leader) == {:raised, "boom"}
      assert Task.await(waiter) == {:ok, :recovered}
    end
  end
end
