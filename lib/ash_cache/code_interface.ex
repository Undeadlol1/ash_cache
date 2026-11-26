defmodule AshCache.CodeInterface do
  @moduledoc false

  alias AshCache.CachedRead
  alias AshCache.CacheVersion
  alias AshCache.Info
  alias AshCache.Preparations.ReadThrough
  alias AshCache.Store

  # The `cache` section's `after_define`. It runs in the module body after
  # `use Ash.Resource`, so this hook runs after the one where Ash defines
  # the code-interface functions.
  @doc false
  def register_hook do
    quote do
      unless Module.get_attribute(__MODULE__, :ash_cache_code_interface) do
        @ash_cache_code_interface true
        @before_compile AshCache.CodeInterface
      end
    end
  end

  defmacro __before_compile__(env) do
    resource = env.module
    wrap(env, Enum.map(Ash.Resource.Info.interfaces(resource), &{resource, &1}))
  end

  @doc false
  def wrap(env, interfaces) do
    defined = Module.definitions_in(env.module, :def)

    for {resource, %Ash.Resource.Interface{} = interface} <- interfaces,
        config <- List.wrap(config(env.module, resource, interface)),
        {function, kind} <- functions(interface),
        arity <- List.wrap(full_arity(defined, function)) do
      wrapper(function, arity, kind, config)
    end
  end

  defp config(module, resource, interface) do
    action = interface.action || interface.name

    with true <- AshCache.Resource in Spark.extensions(resource),
         %CachedRead{} = cached_read <-
           Enum.find(Info.cache(resource), &match?(%CachedRead{name: ^action}, &1)) do
      store = Info.cache_store!(resource)
      ttl = CachedRead.ttl(cached_read, Info.cache_ttl!(resource))

      {module, resource, action, store, Info.cache_clear_when_changed!(resource),
       Keyword.put(cached_read.store_options, :ttl, ttl)}
    else
      _not_cached -> nil
    end
  end

  defp functions(%{name: name}) do
    if name |> to_string() |> String.ends_with?("?") do
      [
        {name |> to_string() |> String.trim_trailing("?") |> String.to_atom(), :safe},
        {name, :bang}
      ]
    else
      [{name, :safe}, {:"#{name}!", :bang}]
    end
  end

  defp full_arity(defined, function) do
    case for {^function, arity} <- defined, arity >= 2, do: arity do
      [] -> nil
      arities -> Enum.max(arities)
    end
  end

  # Ash's read interface functions end in `params \\ nil, opts \\ nil`; the
  # shorter arities are its defaults and call this one.
  defp wrapper(function, arity, kind, config) do
    args = Macro.generate_arguments(arity - 2, __MODULE__)

    quote do
      defoverridable [{unquote(function), unquote(arity)}]

      def unquote(function)(unquote_splicing(args), params, opts) do
        AshCache.CodeInterface.call(
          unquote(Macro.escape(config)),
          unquote(function),
          unquote(kind),
          [unquote_splicing(args)],
          params,
          opts,
          fn params, opts -> super(unquote_splicing(args), params, opts) end
        )
      end
    end
  end

  @doc false
  def call(config, function, kind, args, params, opts, original) do
    {params, opts} = params_and_opts(params, opts)

    if skip?(opts) do
      original.(params, opts)
    else
      {module, resource, action, store, clear_when_changed, put_opts} = config
      version = CacheVersion.for_key(store, resource, clear_when_changed)
      key = {:ash_cache_call, module, function, version, args, params, Enum.sort(opts)}

      case Store.get(store, key) do
        {:ok, {:ok, value}} ->
          :telemetry.execute([:ash_cache, :read, :hit], %{}, %{
            resource: resource,
            action: action,
            store: store
          })

          if kind == :bang, do: value, else: {:ok, value}

        _miss_or_error ->
          run_and_keep(kind, params, opts, original, {store, key, put_opts})
      end
    end
  end

  # The same split of `params` and `opts` Ash makes for a read interface.
  defp params_and_opts(params, opts) do
    keyword? = Keyword.keyword?(params)

    cond do
      keyword? and is_nil(opts) -> {%{}, params}
      keyword? -> {Map.new(params), opts || []}
      true -> {params || %{}, opts || []}
    end
  end

  defp skip?(opts) do
    opts[:stream?] == true or match?(%{ash_cache: :bypass}, opts[:context])
  end

  defp run_and_keep(kind, params, opts, original, {store, key, put_opts}) do
    mark = make_ref()

    marked_opts =
      Keyword.update(opts, :context, %{ash_cache_call: mark}, &Map.put(&1, :ash_cache_call, mark))

    try do
      result = original.(params, marked_opts)

      with {:ok, _value} = kept <- ok_result(kind, result),
           true <- ReadThrough.take_served_or_stored(mark) do
        Store.put(store, key, kept, put_opts)
      end

      result
    after
      ReadThrough.take_served_or_stored(mark)
    end
  end

  defp ok_result(:bang, value), do: {:ok, value}
  defp ok_result(:safe, result), do: result
end
