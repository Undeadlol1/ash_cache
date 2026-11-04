defmodule AshCache.Test.WidgetScaffold do
  @moduledoc """
  The scaffolding every widget fixture in this file shares.

  Each fixture exists to exercise one AshCache configuration — no caching,
  the flagship block that caches every read, or narrowed options —
  and they differ only in that configuration. The ETS-backed resource
  (private, so per-process — matching the async-test isolation of the
  ProcessLocal store adapter), the attributes, and the actions live here so
  each fixture declares only the cache setup it demonstrates.
  """

  defmacro __using__(opts) do
    extensions = Keyword.get(opts, :extensions, [])
    authorizers = Keyword.get(opts, :authorizers, [])
    domain = Keyword.get(opts, :domain, AshCache.Test.Domain)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: Ash.DataLayer.Ets,
        extensions: unquote(extensions),
        authorizers: unquote(authorizers)

      import AshCache.Test.WidgetScaffold

      ets do
        private?(true)
      end

      unquote(read_policy_of(Keyword.get(opts, :read_policy)))
    end
  end

  defp read_policy_of(nil), do: nil

  # Policy fixtures differ only in the check that guards reads; writes stay
  # open so a test can set up rows without the policy under test in the way.
  defp read_policy_of(read_check) do
    quote do
      policies do
        policy action_type(:read) do
          authorize_if(unquote(read_check))
        end

        policy always() do
          authorize_if(always())
        end
      end
    end
  end

  defmacro widget_attributes do
    quote do
      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:quantity, :integer, allow_nil?: false, default: 0, public?: true)
      end
    end
  end

  defmacro widget_actions(opts \\ []) do
    quote do
      actions do
        defaults([:read, :destroy, create: :*, update: :*])

        read :get_by_name do
          get_by(:name)

          unquote(Keyword.get(opts, :do))
        end

        read :paged do
          pagination(offset?: true, required?: false, default_limit: 2, max_page_size: 100)
        end
      end
    end
  end
end

defmodule AshCache.Test.Widget do
  @moduledoc "Control case: no caching extension at all."

  use AshCache.Test.WidgetScaffold

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.CachedWidget do
  @moduledoc """
  The flagship case: every read cached, every other option left at its default.
  The extra `prepare` proves attached preparations survive the transformer.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:read, ttl: to_timeout(hour: 1))
    read(:get_by_name, ttl: to_timeout(hour: 1))
    read(:paged, ttl: to_timeout(hour: 1))
  end

  widget_attributes()

  widget_actions do
    prepare(build(limit: 10))
  end

  relationships do
    has_many(:parts, AshCache.Test.Part, destination_attribute: :widget_id)
  end

  calculations do
    calculate(:doubled, :integer, expr(quantity * 2))
  end

  aggregates do
    count(:part_count, :parts)
  end
end

defmodule AshCache.Test.Part do
  @moduledoc "Related records for CachedWidget's aggregate."

  use AshCache.Test.WidgetScaffold

  attributes do
    uuid_primary_key(:id)
    attribute(:widget_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: :*])
  end
end

defmodule AshCache.Test.PartiallyCachedWidget do
  @moduledoc """
  Escape-hatch case: custom ttl/store and caching narrowed to one read.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    store(:partial_store)
    read(:get_by_name, ttl: to_timeout(minute: 5), cache_empty?: true)
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.RefreshedWidget do
  @moduledoc """
  Refresh-after-write case: a successful write re-runs the declared read so the
  fresh value is cached before anyone asks for it.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_name, ttl: to_timeout(hour: 1))
    refresh(:get_by_name, arguments: [name: :name])
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.GuardedWidget do
  @moduledoc """
  Authorization case: reads are policy-gated on an actor. A cache hit skips
  the data layer, so cached entries must never become a way around the
  policy that produced them.
  """

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    authorizers: [Ash.Policy.Authorizer],
    read_policy: actor_present()

  cache do
    read(:read, ttl: to_timeout(hour: 1))
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.OwnedWidget do
  @moduledoc """
  Filter-policy case: a read returns only the rows belonging to the actor.
  A read taken with `authorize?: false` on that same actor's behalf sees
  every row, so the two must never share a cache entry.
  """

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    authorizers: [Ash.Policy.Authorizer],
    read_policy: expr(name == ^actor(:id))

  cache do
    read(:read, ttl: to_timeout(hour: 1))
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.ViewerRead do
  @moduledoc false

  use Ash.Resource.ManualRead

  @impl true
  def read(_query, _data_layer_query, _opts, context) do
    {:ok, [struct(AshCache.Test.ViewerWidget, name: context.actor && context.actor.id)]}
  end
end

defmodule AshCache.Test.ViewerWidget do
  @moduledoc "Actor-in-result case: a manual read whose rows depend on the actor but not on the filter."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:with_viewer, ttl: to_timeout(hour: 1))
  end

  widget_attributes()

  actions do
    defaults([:read, create: :*])

    read :with_viewer do
      manual(AshCache.Test.ViewerRead)
    end
  end
end

defmodule AshCache.Test.TwoTtlWidget do
  @moduledoc "Per-read ttl case: two cached reads with different lifetimes."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_name, ttl: to_timeout(hour: 1))
    read(:paged, ttl: to_timeout(minute: 1))
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.DefaultTtlWidget do
  @moduledoc "No ttl anywhere: reads fall back to the built-in default."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_name)
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.BlockTtlWidget do
  @moduledoc "Block ttl: one read inherits it, one overrides it."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    ttl(to_timeout(minute: 2))
    read(:get_by_name)
    read(:paged, ttl: to_timeout(second: 10))
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.InfiniteBlockWidget do
  @moduledoc "Block ttl :infinity, inherited by the read."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    ttl(:infinity)
    read(:get_by_name)
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.InfiniteReadWidget do
  @moduledoc "Per-read ttl :infinity over a finite block ttl."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    ttl(to_timeout(minute: 2))
    read(:get_by_name, ttl: :infinity)
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.TenantWidget do
  @moduledoc "Tenant-isolation case: rows belong to a tenant through an attribute."

  use Ash.Resource,
    domain: AshCache.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  cache do
    read(:read, ttl: to_timeout(hour: 1))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant_id, :string, allow_nil?: false)
    attribute(:name, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: :*])
  end
end

defmodule AshCache.Test.RefreshedTenantWidget do
  @moduledoc "Refresh-after-write case on a multi-tenant resource."

  use Ash.Resource,
    domain: AshCache.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  cache do
    read(:get_by_name, ttl: to_timeout(hour: 1))
    refresh(:get_by_name, arguments: [name: :name])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant_id, :string, allow_nil?: false)
    attribute(:name, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: :*])

    read :get_by_name do
      get_by(:name)
    end
  end
end

defmodule AshCache.Test.MapArgumentWidget do
  @moduledoc "Map-argument case: a cached read taking a map argument."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:filtered, ttl: to_timeout(hour: 1))
  end

  widget_attributes()

  actions do
    defaults([:read, create: :*])

    read :filtered do
      argument(:filters, :map, allow_nil?: false)
    end
  end
end

defmodule AshCache.Test.LabelledWidget do
  @moduledoc """
  Refresh-arguments case: the refreshed read's argument (`label`) is named differently
  from the attribute (`name`) that feeds it.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_label, ttl: to_timeout(hour: 1))
    refresh(:get_by_label, arguments: [label: :name])
  end

  widget_attributes()

  actions do
    defaults([:read, create: :*])

    read :get_by_label do
      argument(:label, :string, allow_nil?: false)
      filter(expr(name == ^arg(:label)))
    end
  end
end

defmodule AshCache.Test.ExchangeRate do
  @moduledoc """
  Generic-action case: a call to an outside service, faked by a function that
  reports each run to the calling process. `"FAIL"` returns an error, `"NONE"`
  an empty list and `"NIL"` nil. Calls need an actor. A write to a Comment
  clears the cached results.

  `:probed` reports each run to the `probe` process and waits for it to send
  `{:answer, result}` (or `{:raise, message}`), so a test controls when a
  run ends.
  """

  use Ash.Resource,
    domain: AshCache.Test.Domain,
    extensions: [AshCache.Resource],
    authorizers: [Ash.Policy.Authorizer]

  cache do
    action(:rates, ttl: to_timeout(hour: 1))
    action(:probed, ttl: to_timeout(hour: 1))
    clear_when_changed([AshCache.Test.Comment])
  end

  policies do
    policy always() do
      authorize_if(actor_present())
    end
  end

  actions do
    action :rates, {:array, :float} do
      allow_nil?(true)
      argument(:currency, :string, allow_nil?: false)

      run(fn input, _context ->
        currency = input.arguments.currency
        send(self(), {:rates_ran, currency})

        case currency do
          "FAIL" -> {:error, "service down"}
          "NONE" -> {:ok, []}
          "NIL" -> {:ok, nil}
          _other -> {:ok, [1.5]}
        end
      end)
    end

    action :probed, :integer do
      argument(:probe, :term, allow_nil?: false)

      run(fn input, _context ->
        send(input.arguments.probe, {:action_run, self()})

        receive do
          {:answer, result} -> result
          {:raise, message} -> raise message
        end
      end)
    end
  end
end

defmodule AshCache.Test.Comment do
  @moduledoc """
  Changed-resource case: caches nothing itself. It uses the extension only so
  its writes are counted, which clears the reads of resources that list it in
  `clear_when_changed`.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.Post do
  @moduledoc "Other-resource case: a write to a Comment clears the cached Post reads."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:read, ttl: to_timeout(hour: 1))
    clear_when_changed([AshCache.Test.Comment])
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.Feed do
  @moduledoc "A second resource listing Comment, next to Post."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    store(:partial_store)
    read(:read, ttl: to_timeout(hour: 1))
    clear_when_changed([AshCache.Test.Comment])
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.SelfListedWidget do
  @moduledoc "A resource that lists itself in `clear_when_changed`."

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:read, ttl: to_timeout(hour: 1))
    clear_when_changed([AshCache.Test.SelfListedWidget])
  end

  widget_attributes()
  widget_actions()
end

defmodule AshCache.Test.ShippingQuote do
  @moduledoc """
  A slow, pure module calculation, faked: each real run sends
  `{:calculated, names}` to the calling process so a test can count runs.
  It reads the record's name and quantity, its parcels and their count, and
  the `:rate` argument. A
  shipment named `"nil"` quotes nil, `"none"` quotes [], and `"fail"` fails
  the whole batch.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:parcel_count, parcels: [:name]]

  @impl true
  def calculate(records, opts, context) do
    send(self(), {:calculated, Enum.map(records, & &1.name)})

    if Enum.any?(records, &(&1.name == "fail")) do
      {:error, "quote service down"}
    else
      {:ok, Enum.map(records, &price(&1, context.arguments[:rate] || 1))}
    end
  end

  defp price(%{name: "nil"}, _rate), do: nil
  defp price(%{name: "none"}, _rate), do: []

  defp price(shipment, rate) do
    parcels = shipment.parcels |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join("+")
    "#{shipment.name}:#{shipment.quantity * rate}:#{shipment.parcel_count}:#{parcels}"
  end
end

defmodule AshCache.Test.Shipment do
  @moduledoc """
  Calculation-caching case: `:quote` is cached per record and
  `:uncached_quote` runs the same calculation without the cache.
  `:cached_read` caches the records themselves too.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:cached_read, ttl: to_timeout(hour: 1))
    calculation(:quote, ttl: to_timeout(hour: 1))
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:quantity, :integer, allow_nil?: false, default: 1, public?: true)
    attribute(:note, :string, public?: true)
  end

  relationships do
    has_many(:parcels, AshCache.Test.Parcel)
  end

  aggregates do
    count(:parcel_count, :parcels)
  end

  calculations do
    calculate :quote, :term, AshCache.Test.ShippingQuote do
      argument(:rate, :integer, default: 1)
    end

    calculate :uncached_quote, :term, AshCache.Test.ShippingQuote do
      argument(:rate, :integer, default: 1)
    end
  end

  actions do
    defaults([:read, create: :*, update: :*])

    read(:cached_read)
  end
end

defmodule AshCache.Test.Parcel do
  @moduledoc "A shipment's parcel, so a calculation can depend on related records."

  use AshCache.Test.WidgetScaffold

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:shipment, AshCache.Test.Shipment, attribute_writable?: true, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshCache.Test.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.Widget)

    resource AshCache.Test.CachedWidget do
      define(:get_cached_widget, action: :read, get_by: [:id])
    end

    resource(AshCache.Test.Part)
    resource(AshCache.Test.PartiallyCachedWidget)
    resource(AshCache.Test.RefreshedWidget)
    resource(AshCache.Test.GuardedWidget)
    resource(AshCache.Test.OwnedWidget)
    resource(AshCache.Test.TwoTtlWidget)
    resource(AshCache.Test.DefaultTtlWidget)
    resource(AshCache.Test.BlockTtlWidget)
    resource(AshCache.Test.InfiniteBlockWidget)
    resource(AshCache.Test.InfiniteReadWidget)
    resource(AshCache.Test.ProbedWidget)
    resource(AshCache.Test.TenantWidget)
    resource(AshCache.Test.ViewerWidget)
    resource(AshCache.Test.RefreshedTenantWidget)
    resource(AshCache.Test.MapArgumentWidget)
    resource(AshCache.Test.LabelledWidget)
    resource(AshCache.Test.ExchangeRate)
    resource(AshCache.Test.Comment)
    resource(AshCache.Test.Post)
    resource(AshCache.Test.Feed)
    resource(AshCache.Test.SelfListedWidget)
    resource(AshCache.Test.Shipment)
    resource(AshCache.Test.Parcel)
  end
end
