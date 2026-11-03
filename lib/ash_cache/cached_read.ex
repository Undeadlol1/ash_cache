defmodule AshCache.CachedRead do
  @moduledoc """
  One cached read action and its own settings: how long its entries live,
  whether empty results are kept, and what is passed to the store adapter.
  """

  defstruct [:name, :ttl, cache_empty?: false, store_options: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          ttl: pos_integer() | :infinity | nil,
          cache_empty?: boolean(),
          store_options: keyword(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc """
  The ttl a cached read or generic action actually uses: its own, else the
  block's.
  """
  @spec ttl(t() | AshCache.CachedAction.t(), pos_integer() | :infinity) ::
          pos_integer() | :infinity
  def ttl(%{ttl: nil}, block_ttl), do: block_ttl
  def ttl(%{ttl: ttl}, _block_ttl), do: ttl

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
      store_options: [
        type: :keyword_list,
        default: [],
        doc:
          "Options passed verbatim to the store adapter's put/4. Couples the resource to that adapter."
      ]
    ]
  end
end
