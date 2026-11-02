defmodule AshCache.TestingTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.FailingWriteAdapter

  defp read_widget!(name) do
    CachedWidget
    |> Ash.Query.for_read(:get_by_name, %{name: name})
    |> Ash.read!()
  end

  describe "capture_events/0" do
    setup do
      AshCache.Testing.capture_events()
    end

    test "delivers miss, hit and invalidate with their metadata" do
      CachedWidget |> Ash.Changeset.for_create(:create, %{name: "w"}) |> Ash.create!()

      read_widget!("w")

      assert_received {:ash_cache, :miss,
                       %{resource: CachedWidget, action: :get_by_name, error: nil}}

      read_widget!("w")
      assert_received {:ash_cache, :hit, %{resource: CachedWidget, action: :get_by_name}}

      :ok = AshCache.invalidate(CachedWidget)
      assert_received {:ash_cache, :invalidate, %{resource: CachedWidget, store: :ash_cache}}
    end

    test "delivers events from a task started by the test" do
      Task.async(fn -> read_widget!("w") end) |> Task.await()

      assert_received {:ash_cache, :miss, %{action: :get_by_name}}
    end

    test "drops events from an unrelated process" do
      test_pid = self()

      spawn(fn ->
        read_widget!("w")
        send(test_pid, :unrelated_done)
      end)

      assert_receive :unrelated_done, 2000
      refute_received {:ash_cache, _, _}
    end

    test "a failed invalidation emits nothing" do
      Process.put(:ash_cache_adapter, FailingWriteAdapter)

      assert {:error, :boom} = AshCache.invalidate(CachedWidget)
      refute_received {:ash_cache, :invalidate, _}
    end
  end

  describe "isolation between concurrent tests" do
    defp capturing_process(parent, name) do
      spawn_link(fn ->
        id = {:isolation_probe, make_ref()}

        :telemetry.attach(
          id,
          [:ash_cache, :invalidate],
          &AshCache.Testing.handle_event/4,
          self()
        )

        send(parent, {:ready, name})

        probe_loop(parent, name)
      end)
    end

    defp probe_loop(parent, name) do
      receive do
        :emit ->
          :ok = AshCache.invalidate(CachedWidget)
          send(parent, {:emitted, name})
          probe_loop(parent, name)

        :report ->
          send(parent, {:received, name, drain([])})
      end
    end

    defp drain(acc) do
      receive do
        {:ash_cache, kind, _metadata} -> drain([kind | acc])
      after
        0 -> acc
      end
    end

    test "each capturing process only sees its own events" do
      first = capturing_process(self(), :first)
      second = capturing_process(self(), :second)
      assert_receive {:ready, :first}, 2000
      assert_receive {:ready, :second}, 2000

      send(first, :emit)
      assert_receive {:emitted, :first}, 2000
      send(first, :report)
      send(second, :report)

      assert_receive {:received, :first, [:invalidate]}, 2000
      assert_receive {:received, :second, []}, 2000
    end
  end

  describe "cleanup" do
    test "the handlers are detached when the test ends" do
      test_pid = self()

      on_exit(fn ->
        assert owned_handlers(test_pid) == []
      end)

      AshCache.Testing.capture_events()

      assert length(owned_handlers(test_pid)) == 3
    end

    defp owned_handlers(test_pid) do
      for event <- [
            [:ash_cache, :read, :hit],
            [:ash_cache, :read, :miss],
            [:ash_cache, :invalidate]
          ],
          handler <- :telemetry.list_handlers(event),
          handler.config == test_pid,
          do: handler
    end
  end
end
