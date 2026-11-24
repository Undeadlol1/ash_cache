defmodule AshCache do
  @moduledoc """
  Declarative read-through caching for Ash read and generic actions. See
  `AshCache.Resource` for the DSL and `README.md` in this directory for the design.

  These helpers are the runtime escape hatch for operational situations
  (a support task, a migration) that need to reach past the declarative
  layer.

  ## Telemetry

  Nine `:telemetry` events let you assert cache behaviour in tests and
  measure hit rates in production. All have empty measurements. Calls that
  are bypassed, or not cached, emit nothing. Actor and tenant are never in
  the metadata.

    * `[:ash_cache, :read, :hit]` - a cached read was answered without the
      data layer: from the store, or with the records of an identical read
      running at the same time (see `AshCache.Coalesce`). Metadata:
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
    * `[:ash_cache, :remember, :hit]` and `[:ash_cache, :remember, :miss]` -
      a `remember/4` call was answered from the store, or ran its loader.
      A loader that returns an error, and a store that cannot answer, are
      misses. Metadata: `:resource`, `:store`, `:key`; the key is the one you
      passed, so keep nothing secret in it.
    * `[:ash_cache, :invalidate]` - a resource's cache was invalidated, by
      a successful create, update or destroy or by `invalidate/1`.
      Metadata: `:resource`, `:store`.
  """

  alias AshCache.CacheVersion
  alias AshCache.Coalesce
  alias AshCache.Info
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
  Keeps one small derived value in the resource's store and answers it
  without running any Ash action.

  A hit costs one version lookup and one store lookup: no query is built, no
  policy is checked, and `loader` is not called. A cached read runs the whole
  Ash pipeline even on a hit; use `remember/4` for a small fact asked many
  times per request (a feature-flag snapshot, one user's setting), and a
  cached read for everything else.

      AshCache.remember(MyApp.FeatureFlag, :every_flag, fn ->
        {:ok, MyApp.FeatureFlag.list_enabled_names!()}
      end, ttl: :timer.minutes(1))

  **You own authorization.** The value is whatever `loader` returned, handed
  to every caller who passes the same `key`. `key` must therefore contain
  everything the value depends on, such as the user id, or one caller is
  given another's value.

  `loader` returns `{:ok, value}` or `{:error, reason}`. Any `value` is kept,
  `nil`, `false` and `[]` included. An error is returned and not kept; a
  raise propagates and keeps nothing. Identical misses at once on one server
  share one `loader` run (see `AshCache.Coalesce`).

  The value lives as long as a cached read of `resource` would: every create,
  update or destroy of `resource`, of a resource in its `clear_when_changed`,
  and `invalidate/1` drop it. Writes made outside Ash need `forget/2`.
  Remembering is not transaction-aware, like the cached reads: a value
  loaded inside an open transaction is kept even if it rolls back.

  A store that fails never breaks the call: the loader runs and its answer
  is returned.

  ## Options

    * `:ttl` - milliseconds, or `:infinity`. Defaults to the `ttl` of the
      resource's `cache` block.
  """
  @spec remember(module(), term(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def remember(resource, key, loader, opts \\ []) when is_function(loader, 0) do
    store = store!(resource)
    entry_key = entry_key(store, resource, key)
    ttl = Keyword.get_lazy(opts, :ttl, fn -> Info.cache_ttl!(resource) end)
    remembering = %{resource: resource, store: store, key: key, entry_key: entry_key, ttl: ttl}

    look_up(remembering, loader)
  end

  @doc """
  Drops one value kept by `remember/4`, for a value that changed without an
  Ash write to `resource`.
  """
  @spec forget(module(), term()) :: :ok | {:error, term()}
  def forget(resource, key) do
    store = store!(resource)
    Store.delete(store, entry_key(store, resource, key))
  end

  defp look_up(remembering, loader) do
    case Store.get(remembering.store, remembering.entry_key) do
      {:ok, {:remembered, value}} ->
        emit_remember(:hit, remembering)
        {:ok, value}

      {:ok, nil} ->
        rebuild(remembering, loader)

      {:error, _reason} ->
        emit_remember(:miss, remembering)
        loader.()
    end
  end

  defp rebuild(remembering, loader) do
    case Coalesce.join({remembering.store, remembering.entry_key}) do
      {:shared, value} ->
        emit_remember(:hit, remembering)
        {:ok, value}

      :retry ->
        look_up(remembering, loader)

      :lead ->
        lead(remembering, loader)

      :alone ->
        emit_remember(:miss, remembering)
        load_and_keep(remembering, loader)
    end
  end

  defp lead(remembering, loader) do
    {outcome, result} =
      case Store.get(remembering.store, remembering.entry_key) do
        {:ok, {:remembered, value}} ->
          emit_remember(:hit, remembering)
          {{:ok, value}, {:ok, value}}

        _miss_or_error ->
          emit_remember(:miss, remembering)

          case load_and_keep(remembering, loader) do
            {:ok, value} = result -> {{:ok, value}, result}
            error -> {:failed, error}
          end
      end

    Coalesce.release({remembering.store, remembering.entry_key}, outcome)
    result
  catch
    kind, reason ->
      Coalesce.release({remembering.store, remembering.entry_key}, :failed)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp load_and_keep(remembering, loader) do
    with {:ok, value} = result <- loader.() do
      Store.put(remembering.store, remembering.entry_key, {:remembered, value},
        ttl: remembering.ttl
      )

      result
    end
  end

  # The stored value is wrapped: a store answers `{:ok, nil}` for a miss, so
  # a remembered `nil` would otherwise read back as one.
  defp entry_key(store, resource, key) do
    version = CacheVersion.for_key(store, resource, Info.cache_clear_when_changed!(resource))
    {:ash_cache_remembered, resource, version, key}
  end

  defp store!(resource) do
    if Info.cached?(resource) do
      Info.cache_store!(resource)
    else
      raise ArgumentError,
            "#{inspect(resource)} does not use the AshCache.Resource extension, " <>
              "so it has no cache store to remember values in"
    end
  end

  defp emit_remember(event, %{resource: resource, store: store, key: key}) do
    :telemetry.execute([:ash_cache, :remember, event], %{}, %{
      resource: resource,
      store: store,
      key: key
    })
  end
end
