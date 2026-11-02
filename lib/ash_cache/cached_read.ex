defmodule AshCache.CachedRead do
  @moduledoc """
  One cached read action and its own settings: how long its entries live,
  whether empty results are kept, and what is passed to the store adapter.
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
    [
      name: [
        type: :atom,
        required: true,
        doc: "The read action to cache."
      ],
      ttl: [
        type: :pos_integer,
        required: true,
        doc: "Milliseconds a cached entry of this read lives before it expires."
      ],
      cache_empty?: [
        type: :boolean,
        default: false,
        doc: "Whether empty results ([] or nil) are cached. Off by default."
      ],
      adapter_options: [
        type: :keyword_list,
        default: [],
        doc:
          "Options passed verbatim to the store adapter's put/4. Couples the resource to that adapter."
      ]
    ]
  end
end
