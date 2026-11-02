defmodule AshCache.Store.Adapter do
  @moduledoc """
  Behaviour every AshCache storage adapter implements.

  Deliberately the plainest possible key/value contract, so an adapter
  already written against another cache facade ports one-to-one. A miss is
  `{:ok, nil}`, never an error tuple.
  """

  @callback get(store :: atom(), key :: term()) :: {:ok, term()} | {:error, term()}
  @doc """
  Stores a value. Recognised options:

    * `:ttl` — milliseconds, or `:infinity`
    * `:pin` — exempt this entry from any capacity bound the adapter
      enforces. For metadata an adapter must not drop on its own, such as
      the generation counters cache invalidation reads. Adapters without a
      bound ignore it.
  """
  @callback put(store :: atom(), key :: term(), value :: term(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback delete(store :: atom(), key :: term()) :: :ok | {:error, term()}
  @callback clear(store :: atom()) :: :ok | {:error, term()}
end
