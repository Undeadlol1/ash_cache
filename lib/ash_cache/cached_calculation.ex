defmodule AshCache.CachedCalculation do
  @moduledoc """
  One cached module calculation and its own settings: how long its entries
  live and what is passed to the store adapter. `nil` and `[]` results are
  real answers, so they are always cached.
  """

  defstruct [:name, :ttl, store_options: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          ttl: pos_integer() | :infinity | nil,
          store_options: keyword(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc false
  def schema do
    AshCache.CachedRead.schema()
    |> Keyword.delete(:cache_empty?)
    |> Keyword.put(:name, type: :atom, required: true, doc: "The calculation to cache.")
  end
end
