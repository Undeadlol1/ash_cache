defmodule AshCache.CachedRead do
  @moduledoc """
  One cached read action and its own settings: how long its entries live,
  whether empty results are kept, and what is passed to the store adapter.
  """

  defstruct [:name, :ttl, cache_empty?: false, adapter_options: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          ttl: pos_integer() | :infinity | nil,
          cache_empty?: boolean(),
          adapter_options: keyword(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc """
  The ttl a cached read actually uses: its own, else the block's.
  """
  @spec effective_ttl(t(), pos_integer() | :infinity) :: pos_integer() | :infinity
  def effective_ttl(%__MODULE__{ttl: nil}, section_ttl), do: section_ttl
  def effective_ttl(%__MODULE__{ttl: ttl}, _section_ttl), do: ttl

  @doc false
  def schema do
    [
      name: [
        type: :atom,
        required: true,
        doc: "The read action to cache."
      ],
      ttl: [
        type: {:or, [:pos_integer, {:in, [:infinity]}]},
        doc: """
        Milliseconds a cached entry of this read lives before it expires, or
        `:infinity` to never expire. Defaults to the `cache` block's `ttl`.
        """
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
