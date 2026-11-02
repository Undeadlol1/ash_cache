defmodule AshCache.Actions.RunThrough do
  @moduledoc """
  Caching for a generic action.

  Ash has no way for a hook to skip a generic action's `run`, so
  `AshCache.Resource.Transformers.AttachCacheHooks` puts this module in the
  action's place and hands it the original `run` as the `:run` option. On a
  hit the original is never called; on a miss it is called and a successful
  result is cached.

  Ash checks authorization before calling `run`, so a hit is still
  authorized. Hooks, `allow_nil?` and loading of the result run on a hit too.

  The key holds the action's arguments, the actor and the tenant
  (`AshCache.Key`). Errors, `nil` and (unless `cache_empty?: true`) `[]` are
  not cached. `Ash.ActionInput.set_context(input, %{ash_cache: :bypass})`
  skips the cache for one call.
  """

  use Ash.Resource.Actions.Implementation

  alias AshCache.Generation
  alias AshCache.Key
  alias AshCache.Store

  @impl true
  def run(%{context: %{ash_cache: :bypass}} = input, opts, context) do
    run_original(input, opts, context)
  end

  def run(input, opts, context) do
    store = Keyword.fetch!(opts, :store)

    key =
      Key.derive(
        input.resource,
        input.action.name,
        %{arguments: input.arguments},
        Generation.current(store, input.resource),
        actor: context.actor,
        tenant: context.tenant
      )

    case Store.get(store, key) do
      {:ok, nil} ->
        emit(:miss, input, store, error: nil)
        run_and_cache(input, opts, context, store, key)

      {:ok, result} ->
        emit(:hit, input, store)
        {:ok, result}

      {:error, reason} ->
        emit(:miss, input, store, error: reason)
        run_original(input, opts, context)
    end
  end

  defp run_and_cache(input, opts, context, store, key) do
    result = run_original(input, opts, context)

    with {:ok, value} <- ok_value(result),
         true <- cacheable?(value, Keyword.get(opts, :cache_empty?, false)) do
      put_opts = Keyword.put(Keyword.get(opts, :adapter_options, []), :ttl, opts[:ttl])
      Store.put(store, key, value, put_opts)
    end

    result
  end

  defp ok_value({:ok, value}), do: {:ok, value}
  defp ok_value({:ok, value, _notifications}), do: {:ok, value}
  defp ok_value(_error), do: :error

  # nil means "not in the store", so a cached nil would read back as a miss.
  defp cacheable?(nil, _cache_empty?), do: false
  defp cacheable?(value, cache_empty?), do: cache_empty? or value != []

  defp run_original(input, opts, context) do
    {module, run_opts} = Keyword.fetch!(opts, :run)
    Ash.Resource.Actions.Implementation.run(module, input, run_opts, context)
  end

  defp emit(event, input, store, extra \\ []) do
    metadata = %{resource: input.resource, action: input.action.name, store: store}
    :telemetry.execute([:ash_cache, :action, event], %{}, Map.merge(metadata, Map.new(extra)))
  end
end
