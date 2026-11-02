defmodule AshCache.Test.FailingGetAdapter do
  @moduledoc false

  @behaviour AshCache.Store.Adapter

  alias AshCache.Store.Adapters.ProcessLocal

  @impl true
  def get(_store, _key), do: {:error, :boom}

  @impl true
  defdelegate put(store, key, value, opts), to: ProcessLocal

  @impl true
  defdelegate del(store, key), to: ProcessLocal

  @impl true
  defdelegate clear(store), to: ProcessLocal
end
