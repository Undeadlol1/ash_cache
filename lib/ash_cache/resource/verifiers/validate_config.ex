defmodule AshCache.Resource.Verifiers.ValidateConfig do
  @moduledoc """
  Rejects a `reads` list naming an action that is not a read action on the
  resource — a typo there would silently cache nothing.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @doc false
  def verify(dsl_state) do
    with :ok <- verify_reads(dsl_state) do
      verify_warms(dsl_state)
    end
  end

  defp verify_reads(dsl_state) do
    case Verifier.get_option(dsl_state, [:cache], :reads) do
      :all -> :ok
      read_names -> validate_read_names(dsl_state, read_names)
    end
  end

  defp verify_warms(dsl_state) do
    cached_reads =
      case Verifier.get_option(dsl_state, [:cache], :reads) do
        :all -> read_action_names(dsl_state)
        read_names -> MapSet.new(read_names)
      end

    dsl_state
    |> Verifier.get_entities([:cache])
    |> Enum.reject(&MapSet.member?(cached_reads, &1.read))
    |> case do
      [] ->
        :ok

      [%{read: uncached} | _rest] ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:cache, :warm],
           message: """
           `warm #{inspect(uncached)}` names an action that is not a cached read on this resource.
           Cached read actions: #{inspect(Enum.sort(cached_reads))}.
           """
         )}
    end
  end

  defp read_action_names(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:actions])
    |> Enum.filter(&(&1.type == :read))
    |> MapSet.new(& &1.name)
  end

  defp validate_read_names(dsl_state, read_names) do
    known_reads = read_action_names(dsl_state)

    case Enum.reject(read_names, &MapSet.member?(known_reads, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:cache, :reads],
           message: """
           `reads` names actions that are not read actions on this resource: #{inspect(unknown)}.
           Known read actions: #{inspect(Enum.sort(known_reads))}.
           """
         )}
    end
  end
end
