defmodule AshCache.Test.PagedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.PagedWidget)
  end
end

defmodule AshCache.Test.PagedWidget do
  @moduledoc "Pagination case: cached reads paged by keyset and by offset, with counts."

  use AshCache.Test.WidgetScaffold,
    extensions: [AshCache.Resource],
    domain: AshCache.Test.PagedDomain

  cache do
    read(:keyset, ttl: to_timeout(hour: 1))
    read(:offset, ttl: to_timeout(hour: 1))
  end

  widget_attributes()

  actions do
    defaults([:read, create: :*])

    read :keyset do
      prepare(build(sort: [name: :asc]))
      pagination(keyset?: true, required?: false, default_limit: 2, countable: true)
    end

    read :offset do
      prepare(build(sort: [name: :asc]))
      pagination(offset?: true, required?: false, default_limit: 2, countable: true)
    end
  end
end
