defmodule AshCache.Dependencies do
  @moduledoc """
  Which other resources a read's result was computed from.

  A cached entry is cleared by writes to its own resource and to the
  resources in `clear_when_changed`, so a result may only be cached when
  everything it was computed from is among them. Rows can depend on other
  resources through:

    * the filter, including the filter a policy adds (`exists(team.members, ...)`)
    * the sort and distinct, when they use an aggregate or a calculation
    * loaded aggregates, such as a count of comments
    * loaded calculations the data layer computed, such as an expression
      over an aggregate

  Each relationship on such a path counts, and so does the join resource of a
  `many_to_many`: a new join row changes the result as much as a new related
  row does.

  Related records loaded with `load: :comments` do not count. Ash reads them
  after the cached rows on every read, cache hit or not, so they are never
  stale.
  """

  alias Ash.Query.Ref

  @doc """
  Whether every resource `records` were computed from is `query`'s own
  resource or one of `clear_when_changed`.
  """
  @spec all_known?(Ash.Query.t(), [Ash.Resource.record()], [module()]) :: boolean()
  def all_known?(query, records, clear_when_changed) do
    case resources(query, records) do
      {:ok, resources} -> Enum.all?(resources, &(&1 in [query.resource | clear_when_changed]))
      :unknown -> false
    end
  end

  @doc """
  The resources `query` reaches through relationships to compute `records`,
  or `:unknown` when a loaded value cannot be traced back to a definition.
  """
  @spec resources(Ash.Query.t(), [Ash.Resource.record()]) :: {:ok, [module()]} | :unknown
  def resources(query, records) do
    with {:ok, sorted_and_distinct} <- fields(query.resource, sort_fields(query)),
         {:ok, loaded} <- loaded_fields(query.resource, records) do
      expressions = [query.filter | sorted_and_distinct] ++ loaded

      {:ok,
       expressions
       |> Enum.map(&as_expression(query.resource, &1))
       |> Enum.flat_map(&relationship_paths/1)
       |> Enum.flat_map(&along_path(query.resource, &1))
       |> Enum.uniq()}
    end
  end

  # Ash's own walk leaves out the relationship an aggregate counts over when
  # the aggregate has no field and no filter, so those are added from the
  # aggregate references it does return.
  defp relationship_paths(expression) do
    aggregate_paths =
      for {path, refs} <- Ash.Filter.relationship_paths(expression, true, true, true),
          %Ref{attribute: %Ash.Query.Aggregate{relationship_path: counted}} <- refs,
          do: path ++ counted

    Ash.Filter.relationship_paths(expression, true, false, true) ++ aggregate_paths
  end

  defp sort_fields(query) do
    Enum.map(query.sort || [], &sorted_field/1) ++
      Enum.map(query.distinct || [], &sorted_field/1)
  end

  defp sorted_field({field, _order}), do: field
  defp sorted_field(field), do: field

  defp fields(resource, fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case field_definition(resource, field) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp field_definition(_resource, %struct{} = field)
       when struct in [Ash.Query.Aggregate, Ash.Query.Calculation],
       do: {:ok, field}

  defp field_definition(resource, name) when is_atom(name) do
    cond do
      Ash.Resource.Info.aggregate(resource, name) -> loaded(resource, name, :aggregates)
      Ash.Resource.Info.calculation(resource, name) -> loaded(resource, name, :calculations)
      true -> {:ok, nil}
    end
  end

  defp field_definition(_resource, _field), do: :unknown

  # Loading a named field on an empty query is how Ash itself turns a
  # definition into the hydrated aggregate or calculation a query carries.
  defp loaded(resource, name, kind) do
    case resource |> Ash.Query.new() |> Ash.Query.load(name) do
      %{valid?: true} = query -> {:ok, query |> Map.fetch!(kind) |> Map.fetch!(name)}
      _invalid -> :unknown
    end
  end

  # By the time a read's after-action hooks run, Ash has moved the query's
  # aggregates and calculations out of it, so the ones the data layer
  # computed are found on the rows. A value loaded under a name of its own
  # (`Ash.Query.calculate/4`, `Ash.Query.aggregate/4`) has no definition to
  # trace.
  defp loaded_fields(resource, records) do
    if Enum.any?(records, &(&1.calculations != %{} or &1.aggregates != %{})) do
      :unknown
    else
      (Ash.Resource.Info.aggregates(resource) ++ Ash.Resource.Info.calculations(resource))
      |> Enum.filter(fn field -> Enum.any?(records, &loaded?(&1, field.name)) end)
      |> Enum.map(& &1.name)
      |> then(&fields(resource, &1))
    end
  end

  defp loaded?(record, name), do: not match?(%Ash.NotLoaded{}, Map.get(record, name))

  defp as_expression(resource, %struct{} = field)
       when struct in [Ash.Query.Aggregate, Ash.Query.Calculation],
       do: %Ref{attribute: field, relationship_path: [], resource: resource}

  defp as_expression(_resource, expression), do: expression

  defp along_path(resource, path) do
    {resources, _destination} =
      Enum.reduce(path, {[], resource}, fn name, {resources, current} ->
        relationship = Ash.Resource.Info.relationship(current, name)

        {[relationship.destination | join_resource(relationship)] ++ resources,
         relationship.destination}
      end)

    resources
  end

  defp join_resource(%{type: :many_to_many, through: through}), do: [through]
  defp join_resource(_relationship), do: []
end
