defmodule AshCache.Test.Library do
  @moduledoc """
  Related-data cases: authors with books, books with reviews, and authors
  with tags through a join resource. The author fixtures cache their reads
  and differ only in which of these resources they list in
  `clear_when_changed`, and in whether reads are guarded by a policy over
  their books.
  """

  defmacro __using__(opts) do
    clear_when_changed = Keyword.get(opts, :clear_when_changed, [])
    read_policy? = Keyword.get(opts, :read_policy_over_books?, false)

    quote do
      use Ash.Resource,
        domain: AshCache.Test.LibraryDomain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshCache.Resource],
        authorizers: unquote(if read_policy?, do: [Ash.Policy.Authorizer], else: [])

      ets do
        private?(true)
      end

      cache do
        read(:read)
        read(:with_long_books)
        read(:by_total_pages)
        read(:with_books)
        clear_when_changed(unquote(clear_when_changed))
      end

      unquote(if read_policy?, do: AshCache.Test.Library.read_policy_over_books())

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end

      relationships do
        has_many(:books, AshCache.Test.Book, destination_attribute: :author_id, public?: true)

        many_to_many(:tags, AshCache.Test.Tag,
          through: AshCache.Test.AuthorTag,
          source_attribute_on_join_resource: :author_id,
          destination_attribute_on_join_resource: :tag_id,
          public?: true
        )
      end

      aggregates do
        count(:book_count, :books, public?: true)
        sum(:total_pages, :books, :pages, public?: true)
        count(:review_count, [:books, :reviews], public?: true)
        count(:tag_count, :tags, public?: true)
      end

      calculations do
        calculate(:shout, :string, expr(name <> "!"), public?: true)
        calculate(:pages_plus_one, :integer, expr(total_pages + 1), public?: true)
        calculate(:has_long_book?, :boolean, expr(exists(books, pages > 50)), public?: true)
        calculate(:books_counted_in_elixir, :integer, AshCache.Test.CountBooks, public?: true)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])

        read :with_long_books do
          filter(expr(exists(books, pages > 50)))
        end

        read :by_total_pages do
          prepare(build(sort: [total_pages: :desc]))
        end

        read :with_books do
          filter(expr(book_count > 0))
        end
      end
    end
    |> as_field_names()
  end

  @doc false
  def read_policy_over_books do
    quote do
      policies do
        policy action_type(:read) do
          authorize_if(expr(exists(books, pages > 0)))
        end

        policy always() do
          authorize_if(always())
        end
      end
    end
    |> as_field_names()
  end

  # Ash's `expr` reads a bare name as a field only when it carries no macro
  # context, so the names quoted here drop this module's variable hygiene.
  defp as_field_names(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(name) and is_atom(context) -> {name, meta, nil}
      other -> other
    end)
  end
end

defmodule AshCache.Test.CountBooks do
  @moduledoc "A calculation Ash runs in Elixir after the read, by reading books itself."

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def calculate(authors, _opts, _context) do
    Enum.map(authors, fn author ->
      AshCache.Test.Book |> Ash.Query.filter(author_id == ^author.id) |> Ash.count!()
    end)
  end
end

defmodule AshCache.Test.Author do
  @moduledoc "Lists no related resource, so reads over related data are not cached."
  use AshCache.Test.Library
end

defmodule AshCache.Test.BookTrackingAuthor do
  @moduledoc "Lists books, but not reviews, tags or the author-tag join."
  use AshCache.Test.Library, clear_when_changed: [AshCache.Test.Book]
end

defmodule AshCache.Test.TagTrackingAuthor do
  @moduledoc "Lists tags, but not the author-tag join that links them."
  use AshCache.Test.Library, clear_when_changed: [AshCache.Test.Tag]
end

defmodule AshCache.Test.FullyTrackingAuthor do
  @moduledoc "Lists every resource its reads can depend on."
  use AshCache.Test.Library,
    clear_when_changed: [
      AshCache.Test.Book,
      AshCache.Test.Review,
      AshCache.Test.Tag,
      AshCache.Test.AuthorTag
    ]
end

defmodule AshCache.Test.GuardedAuthor do
  @moduledoc "Reads are allowed only for authors with a book: a policy over related data."
  use AshCache.Test.Library, read_policy_over_books?: true
end

defmodule AshCache.Test.BookGuardedAuthor do
  @moduledoc "The same policy, with books listed in `clear_when_changed`."
  use AshCache.Test.Library,
    read_policy_over_books?: true,
    clear_when_changed: [AshCache.Test.Book]
end

defmodule AshCache.Test.Book do
  @moduledoc "Changed resource for the author fixtures; it caches nothing itself."

  use Ash.Resource,
    domain: AshCache.Test.LibraryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, allow_nil?: false, public?: true)
    attribute(:pages, :integer, allow_nil?: false, public?: true)
  end

  relationships do
    has_many(:reviews, AshCache.Test.Review, destination_attribute: :book_id, public?: true)
  end

  aggregates do
    count(:review_count, :reviews, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshCache.Test.Review do
  @moduledoc "Two relationships away from an author, through its books."

  use Ash.Resource,
    domain: AshCache.Test.LibraryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:book_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*])
  end
end

defmodule AshCache.Test.Tag do
  @moduledoc "Reached from an author through the `AuthorTag` join resource."

  use Ash.Resource,
    domain: AshCache.Test.LibraryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*])
  end
end

defmodule AshCache.Test.AuthorTag do
  @moduledoc "Join resource between authors and tags."

  use Ash.Resource,
    domain: AshCache.Test.LibraryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, allow_nil?: false, public?: true)
    attribute(:tag_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*])
  end
end

defmodule AshCache.Test.Loan do
  @moduledoc """
  A row owned by an author through `belongs_to`, read under the usual
  per-owner policy.
  """

  use Ash.Resource,
    domain: AshCache.Test.LibraryDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCache.Resource]

  ets do
    private?(true)
  end

  cache do
    read(:read)
    read(:of_authors_named_ann)
    read(:of_long_books)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, allow_nil?: false, public?: true)
    attribute(:book_id, :uuid, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:author, AshCache.Test.Author, define_attribute?: false, public?: true)

    belongs_to(:long_book, AshCache.Test.Book,
      source_attribute: :book_id,
      define_attribute?: false,
      filter: expr(pages > 50),
      public?: true
    )
  end

  actions do
    defaults([:read, create: :*])

    read :of_authors_named_ann do
      filter(expr(author.name == "Ann"))
    end

    read :of_long_books do
      filter(expr(not is_nil(long_book.id)))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(relates_to_actor_via(:author))
    end

    policy action_type(:create) do
      authorize_if(always())
    end
  end
end

defmodule AshCache.Test.LibraryDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshCache.Test.Author)
    resource(AshCache.Test.BookTrackingAuthor)
    resource(AshCache.Test.TagTrackingAuthor)
    resource(AshCache.Test.FullyTrackingAuthor)
    resource(AshCache.Test.GuardedAuthor)
    resource(AshCache.Test.BookGuardedAuthor)
    resource(AshCache.Test.Book)
    resource(AshCache.Test.Review)
    resource(AshCache.Test.Tag)
    resource(AshCache.Test.AuthorTag)
    resource(AshCache.Test.Loan)
  end
end
