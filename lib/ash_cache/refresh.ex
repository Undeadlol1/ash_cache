defmodule AshCache.Refresh do
  @moduledoc """
  One refresh-after-write declaration: after a successful create or update,
  re-run `read` (with arguments taken from the written record) so the fresh
  value is cached before anyone asks for it.

  Refreshing re-executes the real read action, so it flows through the same
  key derivation, authorization, and caching as any other read — there is
  no separate write-side key reconstruction to drift out of sync.

  It runs synchronously inside the write's `after_transaction` hook, so every
  declaration costs the writing caller one extra read. A refresh that fails is
  logged and swallowed: the write has already committed, and the cache version
  bump has already made the stale entry unreachable.
  """

  defstruct [:read, arguments: [], actor: nil, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          read: atom(),
          arguments: keyword(atom()),
          actor: nil | {module(), atom(), [term()]},
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc false
  def schema do
    [
      read: [
        type: :atom,
        required: true,
        doc: "The cached read action to refresh."
      ],
      arguments: [
        type: :keyword_list,
        default: [],
        doc: "Read arguments as `argument_name: record_attribute` pairs."
      ],
      actor: [
        type: {:or, [nil, :mfa]},
        default: nil,
        doc:
          "MFA returning the actor to refresh as. Refreshed entries are cached under this actor's key, so it must match how the read is normally called."
      ]
    ]
  end
end
