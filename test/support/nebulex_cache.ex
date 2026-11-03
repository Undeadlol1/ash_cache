defmodule AshCache.Test.NebulexCache do
  @moduledoc false
  use Nebulex.Cache, otp_app: :ash_cache, adapter: Nebulex.Adapters.Local
end

defmodule AshCache.Test.PartitionedCache do
  @moduledoc false
  use Nebulex.Cache, otp_app: :ash_cache, adapter: Nebulex.Adapters.Partitioned
end

defmodule AshCache.Test.NebulexWidget do
  @moduledoc """
  A widget cached in a Nebulex cache. Its domain is kept out of the suite's
  `AshCache.Supervisor`, which would otherwise start a Cachex store under
  the cache module's name.
  """

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    domain: AshCache.Test.NebulexDomain

  cache do
    store(AshCache.Test.NebulexCache)
    read(:get_by_name, ttl: to_timeout(hour: 1))
    read(:read, ttl: 1)
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.NebulexDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.NebulexWidget)
  end
end

defmodule AshCache.Test.Peer do
  @moduledoc """
  Runs on a `:peer` node: test modules live only in the test node's memory,
  so anything a peer runs has to be compiled into `test/support`.
  """

  @doc "Joins this node to the partitioned cache, using the Nebulex adapter."
  def start_cache do
    Application.put_env(:ash_cache, :adapter, AshCache.Store.Adapters.Nebulex)
    {:ok, _} = Application.ensure_all_started([:ash_cache, :nebulex_distributed])
    {:ok, pid} = AshCache.Test.PartitionedCache.start_link()
    Process.unlink(pid)
    :ok
  end
end

defmodule AshCache.Test.PartitionedWidget do
  @moduledoc """
  A widget cached in the partitioned Nebulex cache. Its data layer is public
  ETS, which is per server: a peer that did not create a row cannot read it.
  """

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    domain: AshCache.Test.PartitionedDomain

  cache do
    store(AshCache.Test.PartitionedCache)
    read(:get_by_name, ttl: to_timeout(hour: 1))
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.PartitionedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.PartitionedWidget)
  end
end

defmodule AshCache.Test.PeerWidgets do
  @moduledoc """
  Runs on a `:peer` node. Each call arrives in its own short-lived process,
  and ETS rows die with the process that made the table, so every call runs
  inside one long-lived agent.
  """

  alias AshCache.Test.PartitionedWidget

  def start, do: {:ok, _} = Agent.start(fn -> nil end, name: __MODULE__)

  def create(quantity), do: run(fn -> do_create(quantity) end)
  def update(widget, quantity), do: run(fn -> do_update(widget, quantity) end)
  def read, do: run(&do_read/0)

  defp run(fun), do: Agent.get(__MODULE__, fn _ -> fun.() end)

  defp do_create(quantity) do
    PartitionedWidget
    |> Ash.Changeset.for_create(:create, %{name: "w", quantity: quantity})
    |> Ash.create!()
  end

  defp do_update(widget, quantity) do
    widget
    |> Ash.Changeset.for_update(:update, %{quantity: quantity})
    |> Ash.update!()
  end

  defp do_read do
    PartitionedWidget
    |> Ash.Query.for_read(:get_by_name, %{name: "w"})
    |> Ash.read!()
    |> Enum.map(& &1.quantity)
  end

  def forward_events(test_pid) do
    events = [[:ash_cache, :read, :hit], [:ash_cache, :read, :miss]]

    :telemetry.attach_many(
      {__MODULE__, test_pid},
      events,
      &__MODULE__.handle_event/4,
      test_pid
    )
  end

  def handle_event([_, _, kind], _, _, pid), do: send(pid, {:peer_event, node(), kind})
end
