defmodule AshCache.RelatedDataTest do
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshCache.Test.Author
  alias AshCache.Test.AuthorTag
  alias AshCache.Test.Book
  alias AshCache.Test.BookGuardedAuthor
  alias AshCache.Test.BookTrackingAuthor
  alias AshCache.Test.Events
  alias AshCache.Test.FullyTrackingAuthor
  alias AshCache.Test.GuardedAuthor
  alias AshCache.Test.Loan
  alias AshCache.Test.Review
  alias AshCache.Test.Tag
  alias AshCache.Test.TagTrackingAuthor

  # A regression here used to hang forever rather than fail.
  @moduletag timeout: 10_000

  setup do
    AshCache.Testing.capture_events()
  end

  defp create!(resource, attributes) do
    resource
    |> Ash.Changeset.for_create(:create, attributes)
    |> Ash.create!()
  end

  defp author_with_book!(author_resource, pages) do
    author = create!(author_resource, %{name: "Ann"})
    book = create!(Book, %{author_id: author.id, pages: pages})
    {author, book}
  end

  defp set_pages!(book, pages) do
    book |> Ash.Changeset.for_update(:update, %{pages: pages}) |> Ash.update!()
  end

  defp read_twice(resource, opts \\ []) do
    Events.drain()
    Ash.read!(resource, opts)
    [only] = Ash.read!(resource, opts)
    {only, Events.drain()}
  end

  defp read_one(resource, opts) do
    [only] = Ash.read!(resource, opts)
    {only, Events.drain()}
  end

  describe "related records a cached read loads" do
    test "are read fresh on a cache hit, so no resource needs listing" do
      {_author, book} = author_with_book!(Author, 10)
      assert {_author, [:miss, :hit]} = read_twice(Author, load: :books)

      set_pages!(book, 99)
      Events.drain()

      assert {author, [:hit]} = read_one(Author, load: :books)
      assert Enum.map(author.books, & &1.pages) == [99]
    end

    test "carry their own counts fresh too" do
      {_author, book} = author_with_book!(Author, 10)
      assert {_author, [:miss, :hit]} = read_twice(Author, load: [books: :review_count])

      create!(Review, %{book_id: book.id})
      Events.drain()

      assert {author, [:hit]} = read_one(Author, load: [books: :review_count])
      assert Enum.map(author.books, & &1.review_count) == [1]
    end
  end

  describe "a count or sum over related rows" do
    test "is not cached when its resource is not listed, and is always current" do
      {author, _book} = author_with_book!(Author, 10)
      assert {%{book_count: 1}, [:miss, :miss]} = read_twice(Author, load: :book_count)

      create!(Book, %{author_id: author.id, pages: 5})
      Events.drain()

      assert {%{book_count: 2}, [:miss]} = read_one(Author, load: :book_count)
    end

    test "is cached when its resource is listed, and a write to it clears the entry" do
      {_author, book} = author_with_book!(BookTrackingAuthor, 10)

      assert {%{total_pages: 10}, [:miss, :hit]} =
               read_twice(BookTrackingAuthor, load: :total_pages)

      set_pages!(book, 99)
      Events.drain()

      assert {%{total_pages: 99}, [:miss]} = read_one(BookTrackingAuthor, load: :total_pages)
      assert {%{total_pages: 99}, [:hit]} = read_one(BookTrackingAuthor, load: :total_pages)
    end

    test "over a path of two relationships needs every resource on the path listed" do
      {_author, _book} = author_with_book!(BookTrackingAuthor, 10)
      assert {_author, [:miss, :miss]} = read_twice(BookTrackingAuthor, load: :review_count)

      {_author, book} = author_with_book!(FullyTrackingAuthor, 10)

      assert {%{review_count: 0}, [:miss, :hit]} =
               read_twice(FullyTrackingAuthor, load: :review_count)

      create!(Review, %{book_id: book.id})
      Events.drain()

      assert {%{review_count: 1}, [:miss]} = read_one(FullyTrackingAuthor, load: :review_count)
    end

    test "through a join resource needs the join resource listed too" do
      tag = create!(Tag, %{label: "poetry"})

      author = create!(TagTrackingAuthor, %{name: "Ann"})
      create!(AuthorTag, %{author_id: author.id, tag_id: tag.id})
      assert {%{tag_count: 1}, [:miss, :miss]} = read_twice(TagTrackingAuthor, load: :tag_count)

      author = create!(FullyTrackingAuthor, %{name: "Ann"})
      create!(AuthorTag, %{author_id: author.id, tag_id: tag.id})
      assert {%{tag_count: 1}, [:miss, :hit]} = read_twice(FullyTrackingAuthor, load: :tag_count)

      second_tag = create!(Tag, %{label: "prose"})
      create!(AuthorTag, %{author_id: author.id, tag_id: second_tag.id})
      Events.drain()

      assert {%{tag_count: 2}, [:miss]} = read_one(FullyTrackingAuthor, load: :tag_count)
    end
  end

  describe "a calculation" do
    test "over the resource's own fields is cached" do
      author_with_book!(Author, 10)

      assert {%{shout: "Ann!"}, [:miss, :hit]} = read_twice(Author, load: :shout)
    end

    test "over related rows is not cached when they are not listed, and is always current" do
      {_author, book} = author_with_book!(Author, 10)
      assert {%{pages_plus_one: 11}, [:miss, :miss]} = read_twice(Author, load: :pages_plus_one)

      set_pages!(book, 99)
      Events.drain()

      assert {%{pages_plus_one: 100}, [:miss]} = read_one(Author, load: :pages_plus_one)
    end

    test "over related rows is cached when they are listed, and a write to them clears it" do
      {_author, book} = author_with_book!(BookTrackingAuthor, 10)

      assert {%{pages_plus_one: 11}, [:miss, :hit]} =
               read_twice(BookTrackingAuthor, load: :pages_plus_one)

      set_pages!(book, 99)
      Events.drain()

      assert {%{pages_plus_one: 100}, [:miss]} =
               read_one(BookTrackingAuthor, load: :pages_plus_one)
    end

    test "using exists over related rows is not cached when they are not listed" do
      {_author, book} = author_with_book!(Author, 10)

      assert {%{has_long_book?: false}, [:miss, :miss]} =
               read_twice(Author, load: :has_long_book?)

      set_pages!(book, 99)
      Events.drain()

      assert {%{has_long_book?: true}, [:miss]} = read_one(Author, load: :has_long_book?)
    end

    test "computed in Elixir after the read is current even on a cache hit" do
      {author, _book} = author_with_book!(Author, 10)

      assert {%{books_counted_in_elixir: 1}, [:miss, :hit]} =
               read_twice(Author, load: :books_counted_in_elixir)

      create!(Book, %{author_id: author.id, pages: 5})
      Events.drain()

      assert {%{books_counted_in_elixir: 2}, [:hit]} =
               read_one(Author, load: :books_counted_in_elixir)
    end

    test "added to one query without a name on the resource is not cached" do
      author_with_book!(FullyTrackingAuthor, 10)

      query =
        FullyTrackingAuthor
        |> Ash.Query.calculate(:name_twice, :string, expr(name <> name))

      assert {author, [:miss, :miss]} = read_twice(query)
      assert author.calculations.name_twice == "AnnAnn"
    end
  end

  test "a count added to one query without a name on the resource is not cached" do
    author_with_book!(FullyTrackingAuthor, 10)

    query = Ash.Query.aggregate(FullyTrackingAuthor, :books_again, :count, :books)

    assert {author, [:miss, :miss]} = read_twice(query)
    assert author.aggregates.books_again == 1
  end

  describe "a filter or sort over related rows" do
    test "is not cached when they are not listed, and is always current" do
      {_author, book} = author_with_book!(Author, 10)
      assert [] = Ash.read!(Author, action: :with_long_books)

      set_pages!(book, 99)
      Events.drain()

      assert {%{name: "Ann"}, [:miss, :miss]} = read_twice(Author, action: :with_long_books)
    end

    test "is cached when they are listed, and a write to them clears it" do
      {_author, book} = author_with_book!(BookTrackingAuthor, 99)
      assert {_author, [:miss, :hit]} = read_twice(BookTrackingAuthor, action: :with_long_books)

      set_pages!(book, 10)
      Events.drain()

      assert [] = Ash.read!(BookTrackingAuthor, action: :with_long_books)
      assert Events.drain() == [:miss]
    end

    test "filtering on a count of unlisted rows is not cached" do
      author_with_book!(Author, 10)
      assert {_author, [:miss, :miss]} = read_twice(Author, action: :with_books)

      Ash.destroy!(Ash.read_one!(Book))
      Events.drain()

      assert [] = Ash.read!(Author, action: :with_books)
    end

    test "filtering on a count of listed rows is cached" do
      author_with_book!(BookTrackingAuthor, 10)

      assert {_author, [:miss, :hit]} = read_twice(BookTrackingAuthor, action: :with_books)
    end

    test "sorting by a sum over unlisted rows is not cached" do
      author_with_book!(Author, 10)

      assert {_author, [:miss, :miss]} = read_twice(Author, action: :by_total_pages)
    end

    test "sorting by a sum over listed rows is cached" do
      author_with_book!(BookTrackingAuthor, 10)

      assert {_author, [:miss, :hit]} = read_twice(BookTrackingAuthor, action: :by_total_pages)
    end
  end

  describe "a policy over related rows" do
    test "is not cached when they are not listed, so losing access takes effect at once" do
      {_author, book} = author_with_book!(GuardedAuthor, 10)
      assert {_author, [:miss, :miss]} = read_twice(GuardedAuthor)

      Ash.destroy!(book)
      Events.drain()

      assert [] = Ash.read!(GuardedAuthor)
    end

    test "is cached when they are listed, and a write to them clears it" do
      {_author, book} = author_with_book!(BookGuardedAuthor, 10)
      assert {_author, [:miss, :hit]} = read_twice(BookGuardedAuthor)

      Ash.destroy!(book)
      Events.drain()

      assert [] = Ash.read!(BookGuardedAuthor)
      assert Events.drain() == [:miss]
    end
  end

  describe "a read through a belongs_to" do
    setup do
      {author, book} = author_with_book!(Author, 10)
      loan = create!(Loan, %{author_id: author.id, book_id: book.id})
      %{author: author, book: book, loan: loan}
    end

    defp read_loans_twice(action, actor) do
      Events.drain()
      Ash.read!(Loan, action: action, actor: actor)
      loans = Ash.read!(Loan, action: action, actor: actor)
      {loans, Events.drain_for(Loan)}
    end

    test "that only compares its key, as a per-owner policy does, is cached", %{author: author} do
      assert {[_loan], [:miss, :hit]} = read_loans_twice(:read, author)
    end

    test "that reads another field of the related row is not cached", %{author: author} do
      assert {[_loan], [:miss, :miss]} = read_loans_twice(:of_authors_named_ann, author)
    end

    test "whose relationship has a filter of its own is not cached",
         %{author: author, book: book} do
      assert {[], [:miss, :miss]} = read_loans_twice(:of_long_books, author)

      set_pages!(book, 99)

      assert {[_loan], _events} = read_loans_twice(:of_long_books, author)
    end
  end

  test "a read of the resource's own fields is cached as before" do
    author_with_book!(Author, 10)

    assert {%{name: "Ann"}, [:miss, :hit]} = read_twice(Author)
  end
end
