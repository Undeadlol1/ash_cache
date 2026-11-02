defmodule AshCache.CachedAction do
  @moduledoc """
  One cached generic action and its own settings. Takes the same options as
  `AshCache.CachedRead`.
  """

  defstruct [:name, :ttl, cache_empty?: false, adapter_options: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          ttl: pos_integer(),
          cache_empty?: boolean(),
          adapter_options: keyword(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc false
  def schema do
    Keyword.put(AshCache.CachedRead.schema(), :name,
      type: :atom,
      required: true,
      doc: "The generic action to cache."
    )
  end
end
