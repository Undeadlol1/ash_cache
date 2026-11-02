defmodule AshCache.Resource.Verifiers.ValidateConfig do
  @moduledoc """
  Rejects a `cache` block that caches nothing, names an action that is not a
  read action, declares the same read twice, or warms a read it does not cache.
  A typo in any of these would silently cache nothing.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @doc false
  def verify(dsl_state) do
    entities = Verifier.get_entities(dsl_state, [:cache])
    reads = for %AshCache.CachedRead{name: name} <- entities, do: name
    warms = for %AshCache.Warm{read: read} <- entities, do: read

    with :ok <- verify_present(dsl_state, reads),
         :ok <- verify_read_actions(dsl_state, reads),
         :ok <- verify_unique(dsl_state, reads) do
      verify_warms(dsl_state, reads, warms)
    end
  end

  defp verify_present(dsl_state, []),
    do: error(dsl_state, [:cache], "The `cache` block needs at least one `read` to cache.")

  defp verify_present(_dsl_state, _reads), do: :ok

  defp verify_read_actions(dsl_state, reads) do
    known =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.filter(&(&1.type == :read))
      |> MapSet.new(& &1.name)

    case Enum.reject(reads, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      unknown ->
        error(dsl_state, [:cache, :read], """
        `read` names actions that are not read actions on this resource: #{inspect(unknown)}.
        Known read actions: #{inspect(Enum.sort(known))}.
        """)
    end
  end

  defp verify_unique(dsl_state, reads) do
    case Enum.uniq(reads -- Enum.uniq(reads)) do
      [] ->
        :ok

      dupes ->
        error(
          dsl_state,
          [:cache, :read],
          "`read` is declared more than once for: #{inspect(dupes)}."
        )
    end
  end

  defp verify_warms(dsl_state, reads, warms) do
    case Enum.reject(warms, &(&1 in reads)) do
      [] ->
        :ok

      [uncached | _rest] ->
        error(dsl_state, [:cache, :warm], """
        `warm #{inspect(uncached)}` names an action that is not a cached read on this resource.
        Cached read actions: #{inspect(Enum.sort(reads))}.
        """)
    end
  end

  defp error(dsl_state, path, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: path,
       message: message
     )}
  end
end
