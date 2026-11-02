defmodule AshCache.Testing do
  @moduledoc """
  Lets a test see the cache events its own code caused, even when many
  tests run at the same time (`async: true`).

  AshCache announces cache hits, misses and invalidations with `:telemetry`
  (see `AshCache`). Telemetry handlers are global, so a plain handler would
  also catch events from other tests running in parallel. Call
  `capture_events/0` instead:

      setup do
        AshCache.Testing.capture_events()
      end

      test "lookup is cached" do
        MyApp.Shop.get_product_by_sku!("A1")
        MyApp.Shop.get_product_by_sku!("A1")
        assert_received {:ash_cache, :hit, %{action: :get_by_sku}}
      end

  Each event arrives in the test's mailbox as
  `{:ash_cache, kind, metadata}`. `kind` is `:hit`, `:miss` or `:invalidate`,
  and `metadata` is the telemetry metadata described in `AshCache`.

  Only events caused by the test are delivered: those from the test process
  itself and from Tasks it started. Events from any other process, such as a
  GenServer started elsewhere, are dropped. The handler is removed
  automatically when the test ends.
  """

  @events [
    [:ash_cache, :read, :hit],
    [:ash_cache, :read, :miss],
    [:ash_cache, :invalidate]
  ]

  @doc """
  Starts delivering cache events to the calling test process.

  Call it from the test process, in `setup` or in the test itself.
  """
  @spec capture_events() :: :ok
  def capture_events do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle_event(event, _measurements, metadata, test_pid) do
    if from_test?(test_pid) do
      send(test_pid, {:ash_cache, kind(event), metadata})
    end

    :ok
  end

  defp from_test?(test_pid) do
    self() == test_pid or test_pid in Process.get(:"$callers", [])
  end

  defp kind([:ash_cache, :read, kind]), do: kind
  defp kind([:ash_cache, :invalidate]), do: :invalidate
end
