defmodule AshCache.Resource do
  @moduledoc """
  Caches the read actions you declare, each with its own lifetime.

      defmodule MyApp.Shop.Product do
        use Ash.Resource,
          domain: MyApp.Shop,
          extensions: [AshCache.Resource]

        cache do
          read :get_by_sku, ttl: :timer.hours(1)
        end
      end

  Each `read` is cached, keyed by the action, the whole query, the actor and
  the tenant (see `AshCache.Key`). `ttl` is required; empty results are not
  cached unless you ask. Entries go in the shared `:ash_cache` store unless you
  set `store`. Every create, update or destroy clears the resource's cached
  reads after the transaction commits (see `AshCache.Changes.BumpGeneration`).
  So does a write to any resource listed in `clear_when_changed`.

  Reads without a `read` entry are never cached.
  """

  @read %Spark.Dsl.Entity{
    name: :read,
    describe: "Cache this read action, with its own lifetime and settings.",
    target: AshCache.CachedRead,
    args: [:name],
    schema: AshCache.CachedRead.schema()
  }
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
    describe: "Which reads to cache, and where.",
    entities: [@read, @warm],
    schema: [
      store: [
        type: :atom,
        default: :ash_cache,
        doc: "Name of the cache store. Distinct stores isolate eviction and clearing."
      ],
      clear_when_changed: [
        type: {:list, :atom},
        default: [],
        doc: """
        Other resources whose create, update or destroy also clears this
        resource's cached reads, e.g. `clear_when_changed [MyApp.Blog.Comment]`.
        Each one must use the `AshCache.Resource` extension, even if it caches
        nothing itself.
        """
      ]
    ]
  }
  use Spark.Dsl.Extension,
    sections: [@cache],
    transformers: [AshCache.Resource.Transformers.AttachCacheHooks],
    verifiers: [AshCache.Resource.Verifiers.ValidateConfig]
end
