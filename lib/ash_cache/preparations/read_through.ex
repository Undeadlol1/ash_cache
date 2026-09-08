defmodule AshCache.Preparations.ReadThrough do
  @moduledoc """
  Read-through caching for a read action.

  On a cache hit the query result is set via `Ash.Query.set_result/2`, so
  the data layer is never called. On a miss, an `after_action` hook caches
  the records the action returns.

  The cache key is derived inside a `before_action` hook, not at
  preparation time: preparations run before the framework has applied
  everything that shapes the result — a `get_by` code interface, for
  example, attaches its primary-key filter after preparations, so a key
  derived earlier would collide the get with the unfiltered read.

  Safety properties:

    * the cache key embeds actor and tenant (`AshCache.Key`), so a hit can
      only return records the same actor/tenant already read through the
      action's full authorization
    * empty results (`[]`/`nil`) are not cached unless `cache_empty?: true`,
      preventing a transient miss from being served for a whole TTL
    * `Ash.Query.set_context(query, %{ash_cache: :bypass})` skips the cache
      for one query
  """

  use Ash.Resource.Preparation

  alias AshCache.Generation
  alias AshCache.Key
  alias AshCache.Store

  @impl true
  def prepare(query, opts, context) do
    if bypass?(query) do
      query
    else
      Ash.Query.before_action(query, &read_through(&1, opts, context))
    end
  end

  # A bulk update/destroy selects its target rows through a read action.
  # Caching that selection serves stale rows to a mutation, and a
  # before_action hook on it makes Ash refuse the fully-atomic strategy.
  defp bypass?(query) do
    query.context[:ash_cache] == :bypass or
      query.context[:query_for] in [:bulk_update, :bulk_destroy]
  end

  defp read_through(query, opts, context) do
    store = Keyword.fetch!(opts, :store)
    key = derive_key(query, store, context)

    case Store.get(store, key) do
      {:ok, nil} -> cache_after_read(query, store, key, opts)
      {:ok, records} -> Ash.Query.set_result(query, {:ok, records})
      {:error, _reason} -> query
    end
  end

  defp derive_key(query, store, context) do
    generation = Generation.current(store, query.resource)

    # Everything shaping the result set must be keyed on. `Ash.get/2` and
    # get_by interfaces never touch `arguments`, and pagination is applied
    # after this hook — so `filter` and `page` cannot be inferred from the
    # rest, and omitting either collides distinct queries onto one entry.
    query_shape = %{
      arguments: query.arguments,
      filter: query.filter,
      sort: query.sort,
      limit: query.limit,
      offset: query.offset,
      page: query.page,
      distinct: query.distinct,
      select: query.select,
      load: query.load
    }

    Key.derive(query.resource, query.action.name, query_shape, generation,
      actor: Map.get(context, :actor),
      tenant: query.tenant
    )
  end

  defp cache_after_read(query, store, key, opts) do
    ttl = Keyword.fetch!(opts, :ttl)
    cache_empty? = Keyword.get(opts, :cache_empty?, false)
    put_opts = Keyword.put(Keyword.get(opts, :adapter_options, []), :ttl, ttl)

    Ash.Query.after_action(query, fn _query, records ->
      if cacheable?(records, cache_empty?) do
        Store.put(store, key, records, put_opts)
      end

      {:ok, records}
    end)
  end

  defp cacheable?(records, cache_empty?), do: cache_empty? or records not in [nil, []]
end
