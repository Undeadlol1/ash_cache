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

    quote do
      use Ash.Resource,
        domain: AshCache.Test.Domain,
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
        attribute(:value, :integer, allow_nil?: false, default: 0, public?: true)
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

defmodule AshCache.Test.WarmedWidget do
  @moduledoc """
  Warm-after-write case: a successful write re-runs the declared read so the
  fresh value is cached before anyone asks for it.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_name, ttl: to_timeout(hour: 1))
    warm(:get_by_name, args: [name: :name])
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

defmodule AshCache.Test.WarmedTenantWidget do
  @moduledoc "Warm-after-write case on a multi-tenant resource."

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
    warm(:get_by_name, args: [name: :name])
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

defmodule AshCache.Test.FilteredWidget do
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
  Warm-args case: the warmed read's argument (`label`) is named differently
  from the attribute (`name`) that feeds it.
  """

  use AshCache.Test.WidgetScaffold, extensions: [AshCache.Resource]

  cache do
    read(:get_by_label, ttl: to_timeout(hour: 1))
    warm(:get_by_label, args: [label: :name])
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

defmodule AshCache.Test.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.Widget)

    resource AshCache.Test.CachedWidget do
      define(:get_cached_widget, action: :read, get_by: [:id])
    end

    resource(AshCache.Test.PartiallyCachedWidget)
    resource(AshCache.Test.WarmedWidget)
    resource(AshCache.Test.GuardedWidget)
    resource(AshCache.Test.OwnedWidget)
    resource(AshCache.Test.TwoTtlWidget)
    resource(AshCache.Test.TenantWidget)
    resource(AshCache.Test.ViewerWidget)
    resource(AshCache.Test.WarmedTenantWidget)
    resource(AshCache.Test.FilteredWidget)
    resource(AshCache.Test.LabelledWidget)
  end
end
