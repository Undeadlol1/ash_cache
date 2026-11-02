defmodule AshCache.Store.Adapters.Cachex do
  @moduledoc """
  The production store: one Cachex instance per declared cache, started by
  `AshCache.Supervisor`.

  Entries are shared by every process on the node and expire by TTL. It
  enforces no entry bound of its own, so `:never_evict` means nothing here.
  """

  @behaviour AshCache.Store.Adapter

  @impl true
  def get(store, key), do: Cachex.get(store, key)

  @impl true
  def put(store, key, value, opts) do
    # `:never_evict` is meaningless here — this store has no entry bound to be
    # exempt from — and Cachex is not asked to make sense of it.
    case Cachex.put(store, key, value, Keyword.delete(opts, :never_evict)) do
      {:ok, true} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(store, key), do: discard_count(Cachex.del(store, key))

  @impl true
  def clear(store), do: discard_count(Cachex.clear(store))

  defp discard_count({:ok, _removed}), do: :ok
  defp discard_count({:error, reason}), do: {:error, reason}
end
