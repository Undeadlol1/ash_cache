defmodule AshCache.Resource do
  @moduledoc """
  Declarative read-through caching for an Ash resource.

  The zero-config case is the whole point — opt in and every default applies:

      defmodule MyApp.Shop.Product do
        use Ash.Resource,
          domain: MyApp.Shop,
          extensions: [AshCache.Resource]

        cache do
        end
      end

  That alone means:

    * every read action is cached (key: action + the full query shape +
      actor + tenant — see `AshCache.Key`)
    * results live for one hour in the app-wide `:ash_cache` store
    * every create/update/destroy automatically invalidates the resource's
      cached reads after commit (see `AshCache.Changes.BumpGeneration`)
    * empty results are not cached
    * async tests are isolated via the process-local adapter (test config)

  Escape hatches, in increasing depth:

      cache do
        ttl :timer.minutes(5)          # how long entries live
        store :products_cache          # a dedicated store for this resource
        reads [:get_by_sku]            # cache only these read actions
        cache_empty? true              # cache empty results too
        adapter_options [limit: 1_000] # passed verbatim to the store adapter
      end

  Beyond the DSL: bypass one query with
  `Ash.Query.set_context(query, %{ash_cache: :bypass})`, or swap the storage
  adapter (`config :ash_cache, adapter: ...` or
  `Process.put(:ash_cache_adapter, ...)`).
  """

  @warm %Spark.Dsl.Entity{
    name: :warm,
    describe: """
    Re-run a read after every successful create/update so the fresh value is
    cached immediately (write-through), e.g. `warm :get_by_key, args: [key: :key]`.
    """,
    target: AshCache.Warm,
    args: [:read],
    schema: AshCache.Warm.schema()
  }
  @cache %Spark.Dsl.Section{
    name: :cache,
    describe: "Read-through caching configuration. An empty block uses every default.",
    entities: [@warm],
    schema: [
      ttl: [
        type: :pos_integer,
        default: to_timeout(hour: 1),
        doc: "Milliseconds a cached entry lives before it expires."
      ],
      store: [
        type: :atom,
        default: :ash_cache,
        doc: "Name of the cache store. Distinct stores isolate eviction and clearing."
      ],
      reads: [
        type: {:or, [{:list, :atom}, {:in, [:all]}]},
        default: :all,
        doc: "Read action names to cache, or :all (the default)."
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
  }
  use Spark.Dsl.Extension,
    sections: [@cache],
    transformers: [AshCache.Resource.Transformers.AttachCacheHooks],
    verifiers: [AshCache.Resource.Verifiers.ValidateConfig]
end
