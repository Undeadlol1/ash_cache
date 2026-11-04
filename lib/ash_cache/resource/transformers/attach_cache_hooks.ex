defmodule AshCache.Resource.Transformers.AttachCacheHooks do
  @moduledoc """
  Wires caching into the resource's actions at compile time:

    * each cached read action gets the `AshCache.Preparations.ReadThrough`
      preparation, appended after any preparations the action declares
    * each cached generic action has its `run` replaced by
      `AshCache.Actions.RunThrough`, which calls the original on a miss
    * each cached calculation has its implementation replaced by
      `AshCache.Calculations.CalculateThrough`, which calls the original for
      the records not in the cache
    * every create/update/destroy gets the `AshCache.Changes.InvalidateCache`
      change, so invalidation is a property of the resource — an action added
      later cannot forget it
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Dsl
  alias Spark.Dsl.Transformer

  @write_types [:create, :update, :destroy]

  @doc false
  def after?(_transformer), do: true

  @doc false
  def transform(dsl_state) do
    # Read through Info so the defaults apply when there is no `cache` block.
    store = AshCache.Info.cache_store!(dsl_state)
    block_ttl = AshCache.Info.cache_ttl!(dsl_state)
    clear_when_changed = AshCache.Info.cache_clear_when_changed!(dsl_state)
    entities = Transformer.get_entities(dsl_state, [:cache])
    refreshes = Enum.filter(entities, &match?(%AshCache.Refresh{}, &1))

    cached_reads =
      for %AshCache.CachedRead{} = read <- entities, into: %{}, do: {read.name, read}

    cached_actions =
      for %AshCache.CachedAction{} = cached <- entities, into: %{}, do: {cached.name, cached}

    dsl_state = wrap_calculations(dsl_state, entities, block_ttl, store)

    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.reduce(dsl_state, fn action, dsl_state ->
      cond do
        action.type == :read and is_map_key(cached_reads, action.name) ->
          read = cached_reads[action.name]

          preparation_opts = [
            store: store,
            ttl: AshCache.CachedRead.ttl(read, block_ttl),
            cache_empty?: read.cache_empty?,
            store_options: read.store_options,
            clear_when_changed: clear_when_changed
          ]

          attach_preparation(dsl_state, action, preparation_opts)

        action.type == :action and is_map_key(cached_actions, action.name) ->
          cached = cached_actions[action.name]

          run_opts = [
            run: action.run,
            store: store,
            ttl: AshCache.CachedRead.ttl(cached, block_ttl),
            cache_empty?: cached.cache_empty?,
            store_options: cached.store_options,
            clear_when_changed: clear_when_changed
          ]

          replace_action(dsl_state, %{action | run: {AshCache.Actions.RunThrough, run_opts}})

        action.type in @write_types ->
          attach_change(dsl_state, action, store, refreshes)

        true ->
          dsl_state
      end
    end)
    |> then(&{:ok, &1})
  end

  defp wrap_calculations(dsl_state, entities, block_ttl, store) do
    cached =
      for %AshCache.CachedCalculation{} = calc <- entities, into: %{}, do: {calc.name, calc}

    resource = Transformer.get_persisted(dsl_state, :module)

    dsl_state
    |> Transformer.get_entities([:calculations])
    |> Enum.filter(&is_map_key(cached, &1.name))
    |> Enum.reduce(dsl_state, fn calculation, dsl_state ->
      settings = cached[calculation.name]

      opts = [
        calculation: calculation.calculation,
        name: calculation.name,
        resource: resource,
        load: calculation.load,
        store: store,
        ttl: AshCache.CachedRead.ttl(settings, block_ttl),
        store_options: settings.store_options
      ]

      Transformer.replace_entity(
        dsl_state,
        [:calculations],
        %{calculation | calculation: {AshCache.Calculations.CalculateThrough, opts}},
        &(&1.name == calculation.name)
      )
    end)
  end

  defp attach_preparation(dsl_state, action, preparation_opts) do
    preparation =
      Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
        preparation: {AshCache.Preparations.ReadThrough, preparation_opts}
      )

    dsl_state
    |> suppress_primary_read_warning(action)
    |> replace_action(%{action | preparations: action.preparations ++ [preparation]})
  end

  # Ash warns fatally about preparations on a primary read because
  # hand-written ones are usually a mistake. This one is the resource's own
  # opt-in, so it must not demand the flag on every caching resource.
  defp suppress_primary_read_warning(dsl_state, %{primary?: true}) do
    Transformer.persist(dsl_state, :primary_read_warning?, false)
  end

  defp suppress_primary_read_warning(dsl_state, _action), do: dsl_state

  defp attach_change(dsl_state, action, store, refreshes) do
    change_opts =
      case refreshes do
        [] -> [store: store]
        refreshes -> [store: store, refresh: refreshes]
      end

    change =
      Transformer.build_entity!(Dsl, [:actions, action.type], :change,
        change: {AshCache.Changes.InvalidateCache, change_opts}
      )

    replace_action(dsl_state, %{action | changes: action.changes ++ [change]})
  end

  defp replace_action(dsl_state, action) do
    Transformer.replace_entity(dsl_state, [:actions], action, &same_action?(&1, action))
  end

  defp same_action?(%{name: name, type: type}, %{name: name, type: type}), do: true
  defp same_action?(_candidate, _action), do: false
end
