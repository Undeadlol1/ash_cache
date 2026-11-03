defmodule AshCache.Resource do
  @moduledoc """
  Caches the read and generic actions you declare, each with its own lifetime.

      defmodule MyApp.Shop.Product do
        use Ash.Resource,
          domain: MyApp.Shop,
          extensions: [AshCache.Resource]

        cache do
          read :get_by_sku, ttl: :timer.hours(1)
          action :exchange_rate, ttl: :timer.minutes(10)
        end
      end

  Each `read` is cached, keyed by the action, the whole query, the actor and
  the tenant (see `AshCache.Key`). A `read` lives as long as its own `ttl`,
  else the block's `ttl` (5 minutes by default); empty results are not
  cached unless you ask. Entries go in the shared `:ash_cache` store unless you
  set `store`. Every create, update or destroy clears the resource's cached
  reads after the transaction commits (see `AshCache.Changes.InvalidateCache`).
  So does a write to any resource listed in `clear_when_changed`.

  Each `action` caches a generic action, keyed by the action, its arguments,
  the actor and the tenant, with the same `ttl` rules. On a hit its `run` is
  not called (see `AshCache.Actions.RunThrough`). Writes clear these entries
  too.

  Actions without a `read` or `action` entry are never cached.
  """

  @read %Spark.Dsl.Entity{
    name: :read,
    describe: "Cache this read action, with its own lifetime and settings.",
    target: AshCache.CachedRead,
    args: [:name],
    schema: AshCache.CachedRead.schema()
  }
  @action %Spark.Dsl.Entity{
    name: :action,
    describe: "Cache this generic action, with its own lifetime and settings.",
    target: AshCache.CachedAction,
    args: [:name],
    schema: AshCache.CachedAction.schema()
  }
  @refresh %Spark.Dsl.Entity{
    name: :refresh,
    describe: """
    Re-run a read after every successful create/update so the fresh value is
    cached immediately (write-through), e.g. `refresh :get_by_key, arguments: [key: :key]`.
    """,
    target: AshCache.Refresh,
    args: [:read],
    schema: AshCache.Refresh.schema()
  }
  @cache %Spark.Dsl.Section{
    name: :cache,
    describe: "Which reads and generic actions to cache, where, and for how long.",
    entities: [@read, @action, @refresh],
    schema: [
      store: [
        type: :atom,
        default: :ash_cache,
        doc:
          "Name of the cache store. Distinct stores isolate eviction and clearing. With `AshCache.Store.Adapters.Nebulex`, the Nebulex cache module."
      ],
      ttl: [
        type: {:or, [:pos_integer, {:in, [:infinity]}]},
        default: :timer.minutes(5),
        doc: """
        Milliseconds a cached entry lives before it expires, for every `read`
        and `action` that does not set its own `ttl`. `:infinity` never expires; it is never
        the default.
        """
      ],
      clear_when_changed: [
        type: {:list, :atom},
        default: [],
        doc: """
        Other resources whose create, update or destroy also clears this
        resource's cached reads and generic actions, e.g. `clear_when_changed [MyApp.Blog.Comment]`.
        Each one must use the `AshCache.Resource` extension, even if it caches
        nothing itself.
        """
      ]
    ]
  }
  use Spark.Dsl.Extension,
    sections: [@cache],
    transformers: [AshCache.Resource.Transformers.AttachCacheHooks],
    verifiers: [AshCache.Resource.Verifiers.ValidateCacheBlock]
end
