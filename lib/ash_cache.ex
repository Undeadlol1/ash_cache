defmodule AshCache do
  @moduledoc """
  Declarative read-through caching for Ash read and generic actions. See
  `AshCache.Resource` for the DSL and `README.md` in this directory for the design.

  These helpers are the runtime escape hatch for operational situations
  (a support task, a migration) that need to reach past the declarative
  layer.

  ## Telemetry

  Seven `:telemetry` events let you assert cache behaviour in tests and
  measure hit rates in production. All have empty measurements. Calls that
  are bypassed, or not cached, emit nothing. Actor and tenant are never in
  the metadata.

    * `[:ash_cache, :read, :hit]` - a cached read was answered without the
      data layer: from the store, with the records of an identical read
      running at the same time (see `AshCache.Coalesce`), or by `read/4` or
      `read_one/4` without running the action. Metadata:
      `:resource`, `:action`, `:store`.
    * `[:ash_cache, :read, :miss]` - a cached read was not in the store and
      went to the data layer. Metadata: `:resource`, `:action`, `:store`,
      and `:error`, which is `nil` normally or the reason when the store
      failed to answer (the read still goes through).
    * `[:ash_cache, :action, :hit]` and `[:ash_cache, :action, :miss]` -
      the same for a cached generic action, with the same metadata. A miss
      means the action's `run` was called.
    * `[:ash_cache, :calculation, :hit]` and `[:ash_cache, :calculation, :miss]` -
      the same for one record of a cached calculation (see
      `AshCache.Calculations.CalculateThrough`), with `:calculation` in place
      of `:action`. A miss means the calculation ran for that record.
    * `[:ash_cache, :invalidate]` - a resource's cache was invalidated, by
      a successful create, update or destroy or by `invalidate/1`.
      Metadata: `:resource`, `:store`.
  """

  alias AshCache.CachedRead
  alias AshCache.CacheVersion
  alias AshCache.Info
  alias AshCache.Preparations.ReadThrough
  alias AshCache.Store

  @doc """
  Invalidates every cached read and generic action of a resource, exactly
  like a successful write does.
  """
  @spec invalidate(Ash.Resource.t()) :: :ok | {:error, term()}
  def invalidate(resource) do
    CacheVersion.bump(Info.cache_store!(resource), resource)
  end

  @doc "Clears a whole store, including other resources' entries."
  @spec clear_store(atom()) :: :ok | {:error, term()}
  def clear_store(store), do: Store.clear(store)

  @doc """
  The cached read, answered without running the action.

  Returns what `resource |> Ash.Query.for_read(action, params, opts) |>
  Ash.read(opts)` returns. `action` must be a read in the resource's
  `cache` block.

  A read through `Ash.read/2` is served from the cache inside the Ash
  pipeline, so even a hit builds the query, checks policies and runs every
  hook. This call looks up its own entry first, keyed on the resource, the
  action, `params` and the whole `opts` (actor, tenant, load, page,
  context, ...), and a hit costs one version lookup and one store lookup:
  no query, no policy check, no hook. A miss runs the read normally and
  keeps its `{:ok, result}` only when the cached read itself was served
  from, or stored in, the cache, so empty results, `clear_when_changed`
  and store errors follow the read's own rules. Errors are never kept. The
  entry uses the read's `ttl` and `store_options`, and everything that
  clears the read's entries (a create, update or destroy, a write to a
  `clear_when_changed` resource, `invalidate/1`) clears it too.

  Emits `[:ash_cache, :read, :hit]` for a hit it answers itself.
  `context: %{ash_cache: :bypass}` skips the cache.

  Limits:

    * the entry is keyed on the whole actor, so an actor whose attributes
      changed gets a fresh read, but a policy that depends on anything
      else (the time, a setting, a row whose writes do not clear this
      cache) is evaluated again only when the entry expires or is cleared
    * it is not transaction-aware, like the cached read
  """
  @spec read(Ash.Resource.t(), atom(), map() | keyword(), keyword()) ::
          {:ok, [Ash.Resource.record()] | Ash.Page.page()} | {:error, term()}
  def read(resource, action, params \\ %{}, opts \\ []),
    do: cached_call(resource, action, params, opts, :read)

  @doc """
  Like `read/4`, returning what `Ash.read_one/2` returns.
  """
  @spec read_one(Ash.Resource.t(), atom(), map() | keyword(), keyword()) ::
          {:ok, Ash.Resource.record() | nil} | {:error, term()}
  def read_one(resource, action, params \\ %{}, opts \\ []),
    do: cached_call(resource, action, params, opts, :read_one)

  defp cached_call(resource, action, params, opts, kind) do
    cached_read = cached_read!(resource, action)

    if get_in(opts, [:context, :ash_cache]) == :bypass do
      run(resource, action, params, opts, kind)
    else
      store = Info.cache_store!(resource)
      version = CacheVersion.for_key(store, resource, Info.cache_clear_when_changed!(resource))
      key = {:ash_cache_call, resource, version, action, kind, Map.new(params), Enum.sort(opts)}

      case Store.get(store, key) do
        {:ok, {:ok, _result} = hit} ->
          :telemetry.execute([:ash_cache, :read, :hit], %{}, %{
            resource: resource,
            action: action,
            store: store
          })

          hit

        _miss_or_error ->
          run_and_keep(resource, action, params, opts, kind, {store, key, cached_read})
      end
    end
  end

  defp run_and_keep(resource, action, params, opts, kind, {store, key, cached_read}) do
    mark = make_ref()

    marked_opts =
      Keyword.update(opts, :context, %{ash_cache_call: mark}, &Map.put(&1, :ash_cache_call, mark))

    try do
      result = run(resource, action, params, marked_opts, kind)

      if match?({:ok, _result}, result) and ReadThrough.take_served_or_stored(mark) do
        ttl = CachedRead.ttl(cached_read, Info.cache_ttl!(resource))
        Store.put(store, key, result, Keyword.put(cached_read.store_options, :ttl, ttl))
      end

      result
    after
      ReadThrough.take_served_or_stored(mark)
    end
  end

  defp run(resource, action, params, opts, :read),
    do: resource |> Ash.Query.for_read(action, params, opts) |> Ash.read(opts)

  defp run(resource, action, params, opts, :read_one),
    do: resource |> Ash.Query.for_read(action, params, opts) |> Ash.read_one(opts)

  defp cached_read!(resource, action) do
    unless Info.cached?(resource) do
      raise ArgumentError,
            "#{inspect(resource)} does not use the AshCache.Resource extension"
    end

    Enum.find(Info.cache(resource), &match?(%CachedRead{name: ^action}, &1)) ||
      raise ArgumentError,
            "#{inspect(action)} is not a cached read of #{inspect(resource)}: " <>
              "add `read(#{inspect(action)})` to its `cache` block"
  end
end
