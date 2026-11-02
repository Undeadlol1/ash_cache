defmodule AshCache.Test.FailingWriteAdapter do
  @moduledoc false

  @behaviour AshCache.Store.Adapter

  alias AshCache.Store.Adapters.ProcessLocal

  @impl true
  defdelegate get(store, key), to: ProcessLocal

  @impl true
  def put(_store, _key, _value, _opts), do: {:error, :boom}

  @impl true
  def del(_store, _key), do: {:error, :boom}

  @impl true
  defdelegate clear(store), to: ProcessLocal
end
