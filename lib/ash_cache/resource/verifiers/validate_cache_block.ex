defmodule AshCache.Resource.Verifiers.ValidateCacheBlock do
  @moduledoc """
  Rejects a `cache` block that names an action that is not a read action,
  declares the same read twice, refreshes a read it does not cache, or lists in
  `clear_when_changed` a module that is not a resource using AshCache.
  A typo in any of these would silently cache or clear nothing.

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
    refreshes = for %AshCache.Refresh{read: read} <- entities, do: read

    with :ok <- verify_read_actions(dsl_state, reads),
         :ok <- verify_reads_unique(dsl_state, reads),
         :ok <- verify_refreshes(dsl_state, reads, refreshes) do
      verify_clear_when_changed(dsl_state)
    end
  end

  defp verify_read_actions(dsl_state, reads) do
    read_actions =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.filter(&(&1.type == :read))
      |> MapSet.new(& &1.name)

    case Enum.reject(reads, &MapSet.member?(read_actions, &1)) do
      [] ->
        :ok

      not_read_actions ->
        dsl_error(dsl_state, [:cache, :read], """
        `read` names actions that are not read actions on this resource: #{inspect(not_read_actions)}.
        Known read actions: #{inspect(Enum.sort(read_actions))}.
        """)
    end
  end

  defp verify_reads_unique(dsl_state, reads) do
    case Enum.uniq(reads -- Enum.uniq(reads)) do
      [] ->
        :ok

      duplicates ->
        dsl_error(
          dsl_state,
          [:cache, :read],
          "`read` is declared more than once for: #{inspect(duplicates)}."
        )
    end
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
