defmodule AshCache.Test.FailingPutAdapter do
  @moduledoc false

  @behaviour AshCache.Store.Adapter

  alias AshCache.Store.Adapters.ProcessLocal

  @impl true
  defdelegate get(store, key), to: ProcessLocal

  @impl true
  def put(_store, _key, _value, _opts), do: {:error, :boom}

  @impl true
  defdelegate del(store, key), to: ProcessLocal

  @impl true
  defdelegate clear(store), to: ProcessLocal
end
