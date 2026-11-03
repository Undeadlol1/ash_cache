defmodule AshCache.Store.Adapters.Nebulex do
  @moduledoc """
  Stores entries in your own [Nebulex](https://hexdocs.pm/nebulex) cache, so
  several servers can share one cache: Nebulex handles the servers (local,
  partitioned, replicated, multilevel, Redis and so on).

  The store name is the Nebulex cache module, so each cached resource sets
  `store MyApp.Cache`, and you start `MyApp.Cache` in your supervision tree
  instead of `AshCache.Supervisor`. See the storage guide.

  `:never_evict` is dropped: Nebulex has no way to exempt one entry from eviction.
  Losing the counter it was for costs misses, never old data
  (see `AshCache.CacheVersion`). Every other option, including a read's
  `store_options`, is passed to the cache's `put/3`.
  """

  @behaviour AshCache.Store.Adapter

  @impl true
  def get(cache, key), do: call(fn -> cache.get(key, nil, []) end)

  @impl true
  def put(cache, key, value, opts) do
    call(fn -> cache.put(key, value, Keyword.delete(opts, :never_evict)) end)
  end

  @impl true
  def delete(cache, key), do: call(fn -> cache.delete(key, []) end)

  @impl true
  def clear(cache) do
    with {:ok, _deleted} <- call(fn -> cache.delete_all([], []) end), do: :ok
  end

  # Nebulex raises, rather than returns, when the cache is not running —
  # during boot or shutdown, say. AshCache treats any store error as a miss.
  # `is_struct/2`, not `rescue ... in`, so apps without Nebulex compile this
  # module without a warning.
  defp call(fun) do
    fun.()
  rescue
    error ->
      if is_struct(error, Nebulex.CacheNotFoundError),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end
end
