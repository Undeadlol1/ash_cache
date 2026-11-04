defmodule AshCache.RecacheAfterWrite do
  @moduledoc """
  One `recache_after_write` declaration: after a write (a create or an
  update), cache `read` again, so the next request finds the new result.
  Each argument of the read is taken from the written record's field with the
  same name, or from the field `arguments` names for it.

  Recaching re-executes the real read action, so it flows through the same
  key derivation, authorization, and caching as any other read — there is
  no separate write-side key reconstruction to drift out of sync.

  It runs synchronously inside the write's `after_transaction` hook, so every
  declaration costs the writing caller one extra read. A recache that fails is
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

  @doc """
  Which field of the written record fills each argument of `read`, as
  `{argument, field}` pairs: the field `arguments` names, else the field of the
  same name. Arguments with neither are left out, so their defaults apply.
  """
  @spec argument_sources(module(), atom(), keyword(atom())) :: [{atom(), atom()}]
  def argument_sources(resource, read, arguments) do
    for %{name: argument} <- Ash.Resource.Info.action(resource, read).arguments,
        field = Keyword.get(arguments, argument, argument),
        Ash.Resource.Info.attribute(resource, field),
        do: {argument, field}
  end

  @doc false
  def schema do
    [
      read: [
        type: :atom,
        required: true,
        doc: "The cached read action to recache."
      ],
      arguments: [
        type: :keyword_list,
        default: [],
        doc:
          "Read arguments whose field on the written record has a different name, as `argument: field` pairs. An argument with a field of the same name needs no entry."
      ],
      actor: [
        type: {:or, [nil, :mfa]},
        default: nil,
        doc:
          "MFA returning the actor to recache as. Recached entries are cached under this actor's key, so it must match how the read is normally called."
      ]
    ]
  end
end
