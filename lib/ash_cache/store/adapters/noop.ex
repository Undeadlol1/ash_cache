defmodule AshCache.Store.Adapters.Noop do
  @moduledoc """
  Adapter that stores nothing: every read is a miss. Swapping this in
  disables caching entirely without touching any resource.
  """

  @behaviour AshCache.Store.Adapter

  @impl true
  def get(_store, _key), do: {:ok, nil}

  @impl true
  def put(_store, _key, _value, _opts), do: :ok

  @impl true
  def delete(_store, _key), do: :ok

  @impl true
  def clear(_store), do: :ok
end
