defmodule AshCache.Test.ScoredDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.ScoredWidget)
  end
end

defmodule AshCache.Test.ScoredWidget do
  @moduledoc "A read whose own after_action hook changes the rows it returns."

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    domain: AshCache.Test.ScoredDomain

  cache do
    read(:hook_then_cache, ttl: to_timeout(hour: 1))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:score, :integer, allow_nil?: false, default: 0, public?: true)
  end

  actions do
    defaults([:read, create: :*])

    read :hook_then_cache do
      prepare(&__MODULE__.add_hundred/2)
    end

    # The cache preparation is written by hand here, ahead of the hook's.
    read :cache_then_hook do
      prepare({AshCache.Preparations.ReadThrough, store: :ash_cache, ttl: to_timeout(hour: 1)})
      prepare(&__MODULE__.add_hundred/2)
    end
  end

  def add_hundred(query, _context) do
    Ash.Query.after_action(query, fn _query, rows ->
      send(self(), :hook_ran)
      {:ok, Enum.map(rows, &%{&1 | score: &1.score + 100})}
    end)
  end
end
