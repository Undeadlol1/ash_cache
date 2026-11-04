defmodule AshCache.Calculations.CalculateThrough do
  @moduledoc """
  Caching for a module calculation, one entry per record.

  `AshCache.Resource.Transformers.AttachCacheHooks` puts this module in the
  calculation's place and hands it the original as the `:calculation`
  option. `init/1`, `describe/1` and `load/3` are passed to the original,
  so Ash still loads everything the original needs.

  For a batch of records, each record is looked up on its own; the
  original runs once, only for the records that were not found, and the
  results go back in the records' order. `nil` and `[]` are real results
  and are cached. An `{:error, _}` or `:unknown` from the original is
  returned unchanged and nothing is cached.

  The key (`AshCache.Key`) holds the calculation's arguments, the actor,
  the tenant, every attribute of the record and the value of every field
  the original loads: the fields its `load/3` names (asked again with a
  fresh query of the resource) and the calculation's own `load` option.
  So a change to anything the calculation can read gives a new key, and a
  stale result is never served; old entries simply expire after the `ttl`.
  Writes and `AshCache.invalidate/1` do not touch these entries.

  `strict_loads?/0` is `false`, so related records are loaded with all
  their attributes. A callback without options cannot tell what the
  original says, and loading more is always safe.

  A load with `context: %{ash_cache: :bypass}` skips the cache.

  Known limit: identical misses running at the same time each run the
  original; there is no `AshCache.Coalesce` for calculations.
  """

  use Ash.Resource.Calculation

  alias AshCache.Key
  alias AshCache.Store

  @impl true
  def init(opts) do
    {module, calc_opts} = Keyword.fetch!(opts, :calculation)

    with {:ok, calc_opts} <- Ash.Resource.Calculation.init(module, calc_opts) do
      {:ok, Keyword.put(opts, :calculation, {module, calc_opts})}
    end
  end

  @impl true
  def describe(opts) do
    {module, calc_opts} = Keyword.fetch!(opts, :calculation)
    Ash.Resource.Calculation.describe(module, calc_opts)
  end

  @impl true
  def load(query, opts, context) do
    {module, calc_opts} = Keyword.fetch!(opts, :calculation)
    Ash.Resource.Calculation.load(module, query, calc_opts, context)
  end

  @impl true
  def strict_loads?, do: false

  @impl true
  def calculate(records, opts, %{source_context: %{ash_cache: :bypass}} = context) do
    calculate_original(records, opts, context)
  end

  def calculate(records, opts, context) do
    store = Keyword.fetch!(opts, :store)
    fields = loaded_fields(opts, context)
    keys = Enum.map(records, &key(&1, fields, opts, context))
    found = Enum.map(keys, &look_up(store, &1, opts))

    case Enum.reject(Enum.zip([records, keys, found]), &match?({_record, _key, {:ok, _}}, &1)) do
      [] -> Enum.map(found, fn {:ok, value} -> value end)
      misses -> calculate_misses(misses, found, store, opts, context)
    end
  end

  defp calculate_misses(misses, found, store, opts, context) do
    case calculate_original(Enum.map(misses, &elem(&1, 0)), opts, context) do
      {:ok, values} -> {:ok, merge(found, misses, values, store, opts)}
      values when is_list(values) -> {:ok, merge(found, misses, values, store, opts)}
      error_or_unknown -> error_or_unknown
    end
  end

  defp merge(found, misses, values, store, opts) do
    store_opts = Keyword.put(Keyword.get(opts, :store_options, []), :ttl, opts[:ttl])

    for {{_record, key, _miss}, value} <- Enum.zip(misses, values) do
      Store.put(store, key, {:calculated, value}, store_opts)
    end

    fill(found, values)
  end

  defp fill([{:ok, value} | found], values), do: [value | fill(found, values)]
  defp fill([:miss | found], [value | values]), do: [value | fill(found, values)]
  defp fill([], []), do: []

  # Values are stored wrapped, because the store answers nil for "missing"
  # and a nil result must still be a hit.
  defp look_up(store, key, opts) do
    case Store.get(store, key) do
      {:ok, {:calculated, value}} ->
        emit(:hit, opts, store)
        {:ok, value}

      {:ok, _missing} ->
        emit(:miss, opts, store, error: nil)
        :miss

      {:error, reason} ->
        emit(:miss, opts, store, error: reason)
        :miss
    end
  end

  defp key(record, fields, opts, context) do
    resource = Keyword.fetch!(opts, :resource)
    attributes = resource |> Ash.Resource.Info.attribute_names() |> Enum.to_list()

    shape = %{
      arguments: context.arguments,
      attributes: Map.take(record, attributes),
      loaded: Map.new(fields, &{&1, field_value(record, &1)})
    }

    Key.build(resource, {:calculation, opts[:name]}, shape, nil,
      actor: context.actor,
      tenant: context.tenant
    )
  end

  defp field_value(record, field) do
    case record do
      %{^field => value} -> value
      %{aggregates: %{^field => value}} -> value
      %{calculations: %{^field => value}} -> value
      _not_loaded -> nil
    end
  end

  defp loaded_fields(opts, context) do
    {module, calc_opts} = Keyword.fetch!(opts, :calculation)

    module
    |> Ash.Resource.Calculation.load(Ash.Query.new(opts[:resource]), calc_opts, context)
    |> List.wrap()
    |> Enum.concat(List.wrap(opts[:load]))
    |> Enum.map(&field_name/1)
    |> Enum.uniq()
  end

  defp field_name({name, _further}), do: name
  defp field_name(%{name: name}), do: name
  defp field_name(name), do: name

  defp calculate_original(records, opts, context) do
    {module, calc_opts} = Keyword.fetch!(opts, :calculation)
    Ash.Resource.Calculation.calculate(module, records, calc_opts, context)
  end

  defp emit(event, opts, store, extra \\ []) do
    metadata = %{resource: opts[:resource], calculation: opts[:name], store: store}

    :telemetry.execute(
      [:ash_cache, :calculation, event],
      %{},
      Map.merge(metadata, Map.new(extra))
    )
  end
end
