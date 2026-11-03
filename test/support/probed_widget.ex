defmodule AshCache.Test.ProbedRead do
  @moduledoc """
  A data layer the test drives by hand: each read reports itself to the
  `probe` process and returns whatever the test answers, so a test can count
  data-layer reads and hold one open while others pile up behind it.
  """

  use Ash.Resource.ManualRead

  @impl true
  def read(query, _data_layer_query, _opts, _context) do
    send(query.arguments.probe, {:data_layer_read, self()})

    receive do
      {:answer, answer} -> answer
    end
  end
end

defmodule AshCache.Test.ProbedWidget do
  @moduledoc false

  use Ash.Resource, domain: AshCache.Test.Domain, extensions: [AshCache.Resource]

  cache do
    read(:probed, ttl: to_timeout(hour: 1))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:value, :integer, public?: true)
  end

  actions do
    read :probed do
      argument(:probe, :term, allow_nil?: false)
      manual(AshCache.Test.ProbedRead)
    end
  end
end
