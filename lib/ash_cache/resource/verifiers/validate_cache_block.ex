defmodule AshCache.Resource.Verifiers.ValidateCacheBlock do
  @moduledoc """
  Rejects a `cache` block that names an action of the wrong type, declares
  the same action twice, refreshes a read it does not cache, or lists in
  `clear_when_changed` a module that is not a resource using AshCache.
  A typo in any of these would silently cache or clear nothing.

  Also rejects a cached generic action that returns nothing (there is nothing
  to cache) or whose `run` is a Reactor (Ash runs a Reactor itself, so
  AshCache cannot put itself in front of it).

  A resource may cache nothing: it can use the extension only so its writes
  clear the reads of resources that list it in `clear_when_changed`.
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

    with :ok <- verify_action_type(dsl_state, :read, reads, "read actions"),
         :ok <- verify_action_type(dsl_state, :action, actions, "generic actions"),
         :ok <- verify_unique(dsl_state, :read, reads),
         :ok <- verify_unique(dsl_state, :action, actions),
         :ok <- verify_generic_actions(dsl_state, actions),
         :ok <- verify_refreshes(dsl_state, reads, refreshes) do
      verify_clear_when_changed(dsl_state)
    end
  end

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

  # Without the extension a resource's writes change no version, so listing it
  # would compile and never clear anything.
  defp verify_clear_when_changed(dsl_state) do
    dsl_state
    |> Verifier.get_option([:cache], :clear_when_changed, [])
    |> Enum.find_value(:ok, fn module ->
      cond do
        not Ash.Resource.Info.resource?(module) ->
          dsl_error(dsl_state, [:cache, :clear_when_changed], """
          `clear_when_changed` lists #{inspect(module)}, which is not an Ash resource.
          """)

        not AshCache.Info.cached?(module) ->
          dsl_error(dsl_state, [:cache, :clear_when_changed], """
          `clear_when_changed` lists #{inspect(module)}, which does not use AshCache, \
          so its writes are never seen. Add `extensions: [AshCache.Resource]` to it.
          """)

        true ->
          nil
      end
    end)
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
