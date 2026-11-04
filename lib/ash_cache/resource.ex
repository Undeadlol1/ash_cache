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
          calculation :shipping_quote, ttl: :timer.hours(1)
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

  Each `calculation` caches a module calculation's result per record, keyed
  by its arguments, the actor, the tenant and every value it can read from
  the record (see `AshCache.Calculations.CalculateThrough`). It lives as
  long as its own `ttl`, else the block's. Writes do not clear these
  entries: a changed record gives a new key. Expression calculations are
  rejected; they already run in the database and cached reads hold them.

  Actions and calculations without an entry are never cached.
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
  @calculation %Spark.Dsl.Entity{
    name: :calculation,
    describe: "Cache this module calculation's result per record, with its own lifetime.",
    target: AshCache.CachedCalculation,
    args: [:name],
    schema: AshCache.CachedCalculation.schema()
  }
  @recache %Spark.Dsl.Entity{
    name: :recache_after_write,
    describe: """
    After a write (a create or an update), cache this read again, so the next
    request finds the new result. Each argument of the read is taken from the
    written record's field with the same name; `arguments` maps the ones whose
    names differ.
    """,
    target: AshCache.RecacheAfterWrite,
    args: [:read],
    schema: AshCache.RecacheAfterWrite.schema()
  }
  @cache %Spark.Dsl.Section{
    name: :cache,
    describe: "Which reads, generic actions and calculations to cache, where, and for how long.",
    entities: [@read, @action, @calculation, @recache],
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
        Milliseconds a cached entry lives before it expires, for every `read`,
        `action` and `calculation` that does not set its own `ttl`. `:infinity` never expires; it is never
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
