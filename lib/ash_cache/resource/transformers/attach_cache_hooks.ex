defmodule AshCache.Resource.Transformers.AttachCacheHooks do
  @moduledoc """
  Wires caching into the resource's actions at compile time:

    * each cached read action gets the `AshCache.Preparations.ReadThrough`
      preparation, appended after any preparations the action declares
    * every create/update/destroy gets the `AshCache.Changes.BumpGeneration`
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
    store = Transformer.get_option(dsl_state, [:cache], :store)
    entities = Transformer.get_entities(dsl_state, [:cache])
    warm_specs = Enum.filter(entities, &match?(%AshCache.Warm{}, &1))

    cached_reads =
      for %AshCache.CachedRead{} = read <- entities, into: %{}, do: {read.name, read}

    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.reduce(dsl_state, fn action, dsl_state ->
      cond do
        action.type == :read and is_map_key(cached_reads, action.name) ->
          read = cached_reads[action.name]

          read_opts = [
            store: store,
            ttl: read.ttl,
            cache_empty?: read.cache_empty?,
            adapter_options: read.adapter_options
          ]

          attach_preparation(dsl_state, action, read_opts)

        action.type in @write_types ->
          attach_change(dsl_state, action, store, warm_specs)

        true ->
          dsl_state
      end
    end)
    |> then(&{:ok, &1})
  end

  defp attach_preparation(dsl_state, action, read_opts) do
    preparation =
      Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
        preparation: {AshCache.Preparations.ReadThrough, read_opts}
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

  defp attach_change(dsl_state, action, store, warm_specs) do
    change_opts =
      case warm_specs do
        [] -> [store: store]
        warm_specs -> [store: store, warm: warm_specs]
      end

    change =
      Transformer.build_entity!(Dsl, [:actions, action.type], :change,
        change: {AshCache.Changes.BumpGeneration, change_opts}
      )

    replace_action(dsl_state, %{action | changes: action.changes ++ [change]})
  end

  defp replace_action(dsl_state, action) do
    Transformer.replace_entity(dsl_state, [:actions], action, &same_action?(&1, action))
  end

  defp same_action?(%{name: name, type: type}, %{name: name, type: type}), do: true
  defp same_action?(_candidate, _action), do: false
end
