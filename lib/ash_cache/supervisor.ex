defmodule AshCache.Supervisor do
  @moduledoc """
  Starts every cache store declared by the app's resources — the "zero
  manual init" half of the extension. Add it once to the application's
  supervision tree:

      {AshCache.Supervisor, otp_app: :my_app}

  It walks `config :my_app, ash_domains: [...]`, collects the distinct
  `store` names of resources using `AshCache.Resource`, and supervises one
  Cachex instance per store. Resources added later are picked up on the
  next boot with no further wiring.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    ensure_store_available!(AshCache.Store.adapter())

    children =
      opts
      |> configured_domains()
      |> store_names()
      |> Enum.map(&store_child/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The distinct store names declared by the given domains' cached resources."
  @spec store_names([module()]) :: [atom()]
  def store_names(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&AshCache.Info.cached?/1)
    |> Enum.map(&AshCache.Info.cache_store!/1)
    |> Enum.uniq()
  end

  defp configured_domains(opts) do
    case Keyword.fetch(opts, :domains) do
      {:ok, domains} ->
        domains

      :error ->
        opts
        |> Keyword.fetch!(:otp_app)
        |> Application.get_env(:ash_domains, [])
    end
  end

  defp store_child(store) do
    %{id: {:ash_cache_store, store}, start: {__MODULE__, :start_store, [store]}}
  end

  @doc false
  def ensure_store_available!(adapter, cachex_loaded? \\ Code.ensure_loaded?(Cachex)) do
    if adapter == AshCache.Store.Adapters.Cachex and not cachex_loaded? do
      raise ArgumentError,
            "AshCache's default store needs Cachex. " <>
              ~s|Add {:cachex, "~> 3.6"} to your deps, | <>
              "or set config :ash_cache, adapter: YourAdapter."
    end

    :ok
  end

  if Code.ensure_loaded?(Cachex) do
    @doc false
    def start_store(store) do
      case Cachex.start_link(store, []) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _pid}} -> :ignore
        error -> error
      end
    end
  else
    @doc false
    def start_store(_store), do: :ignore
  end
end
