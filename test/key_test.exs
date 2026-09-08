defmodule AshCache.KeyTest do
  use ExUnit.Case, async: true

  alias AshCache.Key

  defmodule FakeResource do
    @moduledoc false
  end

  defmodule FakeUser do
    @moduledoc false
    defstruct [:id]
  end

  describe "derive/5" do
    test "same inputs produce the same key" do
      key_one = Key.derive(FakeResource, :get_by_name, %{name: "a"}, 0, [])
      key_two = Key.derive(FakeResource, :get_by_name, %{name: "a"}, 0, [])

      assert key_one == key_two
    end

    test "map insertion order does not change the key, at any nesting depth" do
      reorderings = [
        {%{alpha: 1, beta: 2, gamma: 3}, %{gamma: 3, beta: 2, alpha: 1}},
        {%{filter: %{alpha: 1, beta: 2}}, %{filter: %{beta: 2, alpha: 1}}}
      ]

      for {args_one, args_two} <- reorderings do
        assert Key.derive(FakeResource, :read, args_one, 0, []) ==
                 Key.derive(FakeResource, :read, args_two, 0, [])
      end
    end

    test "different filters produce different keys, which is what stops an authorized read from answering an unauthorized one" do
      refute Key.derive(FakeResource, :read, %{filter: %{owner_id: "user-1"}}, 0, []) ==
               Key.derive(FakeResource, :read, %{filter: %{owner_id: "user-2"}}, 0, [])
    end

    test "a filter and no filter produce different keys" do
      refute Key.derive(FakeResource, :read, %{filter: %{owner_id: "user-1"}}, 0, []) ==
               Key.derive(FakeResource, :read, %{}, 0, [])
    end

    test "every part of the query shape separates keys, not only the arguments" do
      base = %{
        arguments: %{},
        filter: nil,
        sort: [],
        limit: nil,
        offset: nil,
        page: nil,
        distinct: nil,
        select: nil,
        load: []
      }

      shapes = [
        %{base | sort: [name: :asc]},
        %{base | limit: 10},
        %{base | offset: 10},
        %{base | page: [limit: 10]},
        %{base | distinct: [:name]},
        %{base | select: [:name]},
        %{base | load: [:owner]}
      ]

      unshaped = Key.derive(FakeResource, :read, base, 0, [])

      for shape <- shapes do
        refute Key.derive(FakeResource, :read, shape, 0, []) == unshaped,
               "#{inspect(shape)} does not separate from the unshaped query"
      end
    end

    test "different arguments produce different keys" do
      refute Key.derive(FakeResource, :get_by_name, %{name: "a"}, 0, []) ==
               Key.derive(FakeResource, :get_by_name, %{name: "b"}, 0, [])
    end

    test "different actions produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, []) ==
               Key.derive(FakeResource, :list, %{}, 0, [])
    end

    test "different generations produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, []) ==
               Key.derive(FakeResource, :read, %{}, 1, [])
    end

    test "different resources produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, []) ==
               Key.derive(FakeUser, :read, %{}, 0, [])
    end

    test "different actors produce different keys" do
      key_for_first_actor =
        Key.derive(FakeResource, :read, %{}, 0, actor: %FakeUser{id: "user-1"})

      key_for_second_actor =
        Key.derive(FakeResource, :read, %{}, 0, actor: %FakeUser{id: "user-2"})

      refute key_for_first_actor == key_for_second_actor
    end

    test "an actor and no actor produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, actor: %FakeUser{id: "user-1"}) ==
               Key.derive(FakeResource, :read, %{}, 0, [])
    end

    test "the same actor produces the same key" do
      assert Key.derive(FakeResource, :read, %{}, 0, actor: %FakeUser{id: "user-1"}) ==
               Key.derive(FakeResource, :read, %{}, 0, actor: %FakeUser{id: "user-1"})
    end

    test "different tenants produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, tenant: "org-1") ==
               Key.derive(FakeResource, :read, %{}, 0, tenant: "org-2")
    end

    test "a tenant and no tenant produce different keys" do
      refute Key.derive(FakeResource, :read, %{}, 0, tenant: "org-1") ==
               Key.derive(FakeResource, :read, %{}, 0, [])
    end
  end
end
