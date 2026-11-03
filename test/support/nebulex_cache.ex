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
