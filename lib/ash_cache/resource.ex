defmodule AshCache.Resource do
  @moduledoc """
  Caches the read actions you list.

      defmodule MyApp.Shop.Product do
        use Ash.Resource,
          domain: MyApp.Shop,
          extensions: [AshCache.Resource]

        cache do
          reads [:get_by_sku]
        end
      end

  With only `reads` set:

    * the listed reads are cached, keyed by the action, the whole query,
      the actor and the tenant (see `AshCache.Key`)
    * entries live for one hour in the shared `:ash_cache` store
    * every create, update or destroy clears the resource's cached reads
      after the transaction commits (see `AshCache.Changes.BumpGeneration`)
    * empty results are not cached

  Reads that are not listed are never cached.
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
    describe: "Which reads to cache, and how.",
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
        type: {:list, :atom},
        required: true,
        doc: "The read actions to cache. Reads not listed are never cached."
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
