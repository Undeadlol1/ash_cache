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

  Like reads, the key also holds the version of each resource listed in
  `clear_when_changed`, and identical misses on one server share one `run`
  call (`AshCache.Coalesce`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshCache.CacheVersion
  alias AshCache.Coalesce
  alias AshCache.Key
  alias AshCache.Store

  @impl true
  def run(%{context: %{ash_cache: :bypass}} = input, opts, context) do
    run_original(input, opts, context)
  end

  def run(input, opts, context) do
    store = Keyword.fetch!(opts, :store)

    key =
      Key.build(
        input.resource,
        input.action.name,
        %{arguments: input.arguments},
        CacheVersion.for_key(store, input.resource, Keyword.get(opts, :clear_when_changed, [])),
        actor: context.actor,
        tenant: context.tenant
      )

    look_up(input, opts, context, store, key)
  end

  defp look_up(input, opts, context, store, key) do
    case Store.get(store, key) do
      {:ok, nil} ->
        rebuild(input, opts, context, store, key)

      {:ok, result} ->
        emit(:hit, input, store)
        {:ok, result}

      {:error, reason} ->
        emit(:miss, input, store, error: reason)
        run_original(input, opts, context)
    end
  end

  defp rebuild(input, opts, context, store, key) do
    case Coalesce.join({store, key}) do
      {:shared, result} ->
        emit(:hit, input, store)
        {:ok, result}

      :retry ->
        look_up(input, opts, context, store, key)

      :lead ->
        lead(input, opts, context, store, key)

      :alone ->
        emit(:miss, input, store, error: nil)
        run_and_cache(input, opts, context, store, key)
    end
  end

  # Looks once more: the previous rebuild may have finished between this
  # call's miss and it taking the lead. Waiters are always told the outcome,
  # also when `run` fails or raises.
  defp lead(input, opts, context, store, key) do
    {outcome, result} =
      case Store.get(store, key) do
        {:ok, cached} when not is_nil(cached) ->
          emit(:hit, input, store)
          {{:ok, cached}, {:ok, cached}}

        _miss_or_error ->
          emit(:miss, input, store, error: nil)
          result = run_and_cache(input, opts, context, store, key)

          case ok_value(result) do
            {:ok, value} -> {{:ok, value}, result}
            :error -> {:failed, result}
          end
      end

    Coalesce.release({store, key}, outcome)
    result
  catch
    kind, reason ->
      Coalesce.release({store, key}, :failed)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp run_and_cache(input, opts, context, store, key) do
    result = run_original(input, opts, context)

    with {:ok, value} <- ok_value(result),
         true <- cacheable?(value, Keyword.get(opts, :cache_empty?, false)) do
      store_opts = Keyword.put(Keyword.get(opts, :store_options, []), :ttl, opts[:ttl])
      Store.put(store, key, value, store_opts)
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
