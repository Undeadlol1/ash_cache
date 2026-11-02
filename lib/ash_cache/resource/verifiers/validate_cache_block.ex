defmodule AshCache.Resource.Verifiers.ValidateCacheBlock do
  @moduledoc """
  Rejects a `cache` block that caches nothing, names an action of the wrong
  type, declares the same action twice, or refreshes a read it does not cache.
  A typo in any of these would silently cache nothing.

  Also rejects a cached generic action that returns nothing (there is nothing
  to cache) or whose `run` is a Reactor (Ash runs a Reactor itself, so
  AshCache cannot put itself in front of it).
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @doc false
  def verify(dsl_state) do
    entities = Verifier.get_entities(dsl_state, [:cache])
    reads = for %AshCache.CachedRead{name: name} <- entities, do: name
    actions = for %AshCache.CachedAction{name: name} <- entities, do: name
    refreshes = for %AshCache.Refresh{read: read} <- entities, do: read

    with :ok <- verify_anything_cached(dsl_state, reads ++ actions),
         :ok <- verify_action_type(dsl_state, :read, reads, "read actions"),
         :ok <- verify_action_type(dsl_state, :action, actions, "generic actions"),
         :ok <- verify_unique(dsl_state, :read, reads),
         :ok <- verify_unique(dsl_state, :action, actions),
         :ok <- verify_generic_actions(dsl_state, actions) do
      verify_refreshes(dsl_state, reads, refreshes)
    end
  end

  defp verify_anything_cached(dsl_state, []),
    do:
      dsl_error(
        dsl_state,
        [:cache],
        "The `cache` block needs at least one `read` or `action` to cache."
      )

  defp verify_anything_cached(_dsl_state, _names), do: :ok

  defp verify_action_type(dsl_state, type, names, label) do
    known =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.filter(&(&1.type == type))
      |> MapSet.new(& &1.name)

    case Enum.reject(names, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      wrong_type ->
        dsl_error(dsl_state, [:cache, type], """
        `#{type}` names actions that are not #{label} on this resource: #{inspect(wrong_type)}.
        Known #{label}: #{inspect(Enum.sort(known))}.
        """)
    end
  end

  defp verify_unique(dsl_state, type, names) do
    case Enum.uniq(names -- Enum.uniq(names)) do
      [] ->
        :ok

      duplicates ->
        dsl_error(
          dsl_state,
          [:cache, type],
          "`#{type}` is declared more than once for: #{inspect(duplicates)}."
        )
    end
  end

  defp verify_generic_actions(dsl_state, names) do
    dsl_state
    |> Verifier.get_entities([:actions])
    |> Enum.filter(&(&1.type == :action and &1.name in names))
    |> Enum.find_value(:ok, fn action ->
      {AshCache.Actions.RunThrough, opts} = action.run

      cond do
        is_nil(action.returns) ->
          dsl_error(dsl_state, [:cache, :action], """
          `action #{inspect(action.name)}` returns nothing, so there is nothing to cache.
          Give the action a return type, or remove it from the `cache` block.
          """)

        reactor?(opts[:run]) ->
          dsl_error(dsl_state, [:cache, :action], """
          `action #{inspect(action.name)}` runs a Reactor, which AshCache cannot cache.
          Call the Reactor from a `run` function instead, or remove the action from the `cache` block.
          """)

        true ->
          nil
      end
    end)
  end

  defp reactor?({module, _opts}), do: reactor?(module)

  defp reactor?(module) when is_atom(module) do
    module.spark_is() == Reactor
  rescue
    UndefinedFunctionError -> false
  end

  defp verify_refreshes(dsl_state, reads, refreshes) do
    case Enum.reject(refreshes, &(&1 in reads)) do
      [] ->
        :ok

      [uncached | _rest] ->
        dsl_error(dsl_state, [:cache, :refresh], """
        `refresh #{inspect(uncached)}` names an action that is not a cached read on this resource.
        Cached read actions: #{inspect(Enum.sort(reads))}.
        """)
    end
  end

  defp dsl_error(dsl_state, path, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: path,
       message: message
     )}
  end
end
