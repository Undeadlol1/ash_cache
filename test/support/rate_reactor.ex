defmodule AshCache.Test.RateReactor do
  @moduledoc "A Reactor used as a generic action's `run`, which AshCache cannot cache."

  use Reactor

  input(:currency)

  step :rate do
    argument(:currency, input(:currency))
    run(fn _arguments -> {:ok, [1.5]} end)
  end

  return(:rate)
end
