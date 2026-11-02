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
    * identical misses running at once share one data-layer read
      (`AshCache.Coalesce`). The leader's lease is released in an
      `around_transaction` hook, which wraps the whole read, so a failed or
      raising read still lets its waiters go
  """

  use Ash.Resource.Preparation

  alias AshCache.CacheVersion
  alias AshCache.Coalesce
  alias AshCache.Key
  alias AshCache.Store

  # A bulk update/destroy selects its target rows through a read action.
  # Caching that selection serves stale rows to a mutation, and a
  # before_action hook on it makes Ash refuse the fully-atomic strategy.
  @impl true
  def prepare(query, opts, context) do
    if query.context[:query_for] in [:bulk_update, :bulk_destroy] do
      query
    else
      # Ties this query's rebuild lease to this query, not to the process:
      # a cached read can run another cached read inside it.
      lease = make_ref()

      query
      |> Ash.Query.before_action(&read_through(&1, opts, context, lease))
      |> Ash.Query.around_transaction(&release_on_exit(&1, &2, lease))
    end
  end

  # Checked here, not in prepare/3, so `set_context` after `for_read` works.
  defp read_through(%{context: %{ash_cache: :bypass}} = query, _opts, _context, _lease),
    do: query

  defp read_through(query, opts, context, lease) do
    store = Keyword.fetch!(opts, :store)
    key = build_key(query, store, context)

    case Store.get(store, key) do
      {:ok, nil} ->
        rebuild(query, store, key, opts, context, lease)

      {:ok, records} ->
        emit_read_event(:hit, query, store)
        Ash.Query.set_result(query, {:ok, records})

      {:error, reason} ->
        emit_read_event(:miss, query, store, error: reason)
        query
    end
  end

  defp rebuild(query, store, key, opts, context, lease) do
    case Coalesce.join({store, key}) do
      {:shared, records} ->
        emit_read_event(:hit, query, store)
        Ash.Query.set_result(query, {:ok, records})

      :retry ->
        read_through(query, opts, context, lease)

      :lead ->
        Process.put({:ash_cache_lease, lease}, {store, key})
        lead(query, store, key, opts, lease)

      :alone ->
        emit_read_event(:miss, query, store, error: nil)
        cache_after_read(query, store, key, opts, lease)
    end
  end

  # Looks once more: the previous rebuild may have finished between this
  # request's miss and it taking the lead.
  defp lead(query, store, key, opts, lease) do
    case Store.get(store, key) do
      {:ok, records} when not is_nil(records) ->
        release(lease, {:ok, records})
        emit_read_event(:hit, query, store)
        Ash.Query.set_result(query, {:ok, records})

      _miss_or_error ->
        emit_read_event(:miss, query, store, error: nil)
        cache_after_read(query, store, key, opts, lease)
    end
  end

  defp release_on_exit(query, callback, lease) do
    callback.(query)
  after
    release(lease, :failed)
  end

  defp release(lease, outcome) do
    case Process.delete({:ash_cache_lease, lease}) do
      nil -> :ok
      key -> Coalesce.release(key, outcome)
    end
  end

  defp emit_read_event(event, query, store, extra_metadata \\ []) do
    metadata = %{resource: query.resource, action: query.action.name, store: store}

    :telemetry.execute(
      [:ash_cache, :read, event],
      %{},
      Map.merge(metadata, Map.new(extra_metadata))
    )
  end

  defp build_key(query, store, context) do
    version = CacheVersion.current(store, query.resource)

    # The actor is read from the query at hook time: one passed only to
    # `Ash.read/2` is applied after preparations run, so the preparation
    # context may not hold it.
    #
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

    Key.build(query.resource, query.action.name, query_shape, version,
      actor: actor_of(query, context),
      tenant: query.tenant
    )
  end

  defp actor_of(query, context) do
    case query.context do
      %{private: %{actor: actor}} -> actor
      _no_actor_on_query -> Map.get(context, :actor)
    end
  end

  defp cache_after_read(query, store, key, opts, lease) do
    ttl = Keyword.fetch!(opts, :ttl)
    cache_empty? = Keyword.get(opts, :cache_empty?, false)
    store_opts = Keyword.put(Keyword.get(opts, :store_options, []), :ttl, ttl)

    Ash.Query.after_action(query, fn _query, records ->
      if cacheable?(records, cache_empty?) do
        Store.put(store, key, records, store_opts)
      end

      release(lease, {:ok, records})

      {:ok, records}
    end)
  end

  defp cacheable?(records, cache_empty?), do: cache_empty? or records not in [nil, []]
end
