defmodule AshCache.Store.Adapters.Nebulex do
  @moduledoc """
  Stores entries in your own [Nebulex](https://hexdocs.pm/nebulex) cache, so
  several servers can share one cache: Nebulex handles the servers (local,
  partitioned, replicated, multilevel, Redis and so on).

  The store name is the Nebulex cache module, so each cached resource sets
  `store MyApp.Cache`, and you start `MyApp.Cache` in your supervision tree
  instead of `AshCache.Supervisor`. See the storage guide.

  `:pin` is dropped: Nebulex has no way to exempt one entry from eviction.
  Losing the counter it was for costs misses, never old data
  (see `AshCache.Generation`). Every other option, including a read's
  `adapter_options`, is passed to the cache's `put/3`.
  """

  @behaviour AshCache.Store.Adapter

  @impl true
  def get(cache, key), do: call(fn -> cache.get(key, nil, []) end)

  @impl true
  def put(cache, key, value, opts) do
    call(fn -> cache.put(key, value, Keyword.delete(opts, :pin)) end)
  end

  @impl true
  def del(cache, key), do: call(fn -> cache.delete(key, []) end)

  @impl true
  def clear(cache) do
    with {:ok, _deleted} <- call(fn -> cache.delete_all([], []) end), do: :ok
  end

  # Nebulex raises, rather than returns, when the cache is not running —
  # during boot or shutdown, say. AshCache treats any store error as a miss.
  defp call(fun) do
    fun.()
  rescue
    error in Nebulex.CacheNotFoundError -> {:error, error}
  end
end
