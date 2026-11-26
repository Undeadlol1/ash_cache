defmodule AshCache.CachedCallTest do
  @moduledoc """
  `AshCache.read/4` and `AshCache.read_one/4`: the cached read, answered
  without running the action when the identical call is already cached.
  """

  use ExUnit.Case, async: false

  alias AshCache.Test.CachedWidget
  alias AshCache.Test.Comment
  alias AshCache.Test.CountedWidget
  alias AshCache.Test.Events
  alias AshCache.Test.GuardedWidget
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.Post
  alias AshCache.Test.TenantWidget
  alias AshCache.Test.Widget

  defmodule User do
    @moduledoc false
    defstruct [:id, :role]
  end

  setup do
    AshCache.Testing.capture_events()
    attach_ash_action_probe()
  end

  defp attach_ash_action_probe do
    test = self()
    id = {__MODULE__, make_ref()}
    domain = Ash.Domain.Info.short_name(AshCache.Test.Domain)

    :ok =
      :telemetry.attach_many(
        id,
        [[:ash, :query, :start], [:ash, domain, :read, :start]],
        fn event, _measurements, _metadata, _config ->
          if self() == test, do: send(test, {:ash_ran, event})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp count(message) do
    receive do
      ^message -> 1 + count(message)
    after
      0 -> 0
    end
  end

  defp ash_runs do
    receive do
      {:ash_ran, _event} -> 1 + ash_runs()
    after
      0 -> 0
    end
  end

  defp discard_counts do
    count(:preparation_ran)
    count(:policy_checked)
    ash_runs()
    Events.drain()
  end

  defp create!(resource, attributes, opts \\ []) do
    resource
    |> Ash.Changeset.for_create(:create, attributes, opts)
    |> Ash.create!(opts)
  end

  defp call_entries do
    for {{:ash_cache_entry, _store, {:ash_cache_call, _, _, _, _, _, _} = key}, _value} <-
          Process.get(),
        do: key
  end

  defp call_entry_expiries do
    for {{:ash_cache_entry, _store, {:ash_cache_call, _, _, _, _, _, _}}, {_value, expires_at}} <-
          Process.get(),
        do: expires_at
  end

  defp expire_call_entries do
    for {{:ash_cache_entry, _store, {:ash_cache_call, _, _, _, _, _, _}} = entry_key,
         {value, _expires_at}} <- Process.get() do
      Process.put(entry_key, {value, System.monotonic_time(:millisecond) - 1})
    end
  end

  defp reductions_of(fun) do
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    fun.()
    {:reductions, after_call} = :erlang.process_info(self(), :reductions)
    after_call - before
  end

  defp median_reductions(fun) do
    fun
    |> List.duplicate(21)
    |> Enum.map(&reductions_of/1)
    |> Enum.sort()
    |> Enum.at(10)
  end

  describe "a warm call" do
    test "regression: a warm AshCache.read_one runs no Ash action" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read_one(CountedWidget, :get_by_name, %{name: "w"}, actor: %User{id: 1})
      discard_counts()

      assert {:ok, %CountedWidget{name: "w"}} =
               AshCache.read_one(CountedWidget, :get_by_name, %{name: "w"}, actor: %User{id: 1})

      assert count(:preparation_ran) == 0
      assert count(:policy_checked) == 0
      assert ash_runs() == 0
      assert Events.drain() == [:hit]
    end

    test "regression: a warm AshCache.read runs no Ash action" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 1})
      discard_counts()

      assert {:ok, [%CountedWidget{name: "w"}]} =
               AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 1})

      assert count(:policy_checked) == 0
      assert ash_runs() == 0
    end

    test "regression: a warm hit costs under 750 reductions and a tenth of a warm Ash.read_one" do
      create!(CountedWidget, %{name: "w"})
      actor = %User{id: 1}

      plain_read_one = fn ->
        CountedWidget
        |> Ash.Query.for_read(:get_by_name, %{name: "w"}, actor: actor)
        |> Ash.read_one(actor: actor)
      end

      cached_read_one = fn ->
        AshCache.read_one(CountedWidget, :get_by_name, %{name: "w"}, actor: actor)
      end

      plain_read_one.()
      cached_read_one.()

      plain_cost = median_reductions(plain_read_one)
      cached_cost = median_reductions(cached_read_one)

      assert cached_cost < 750
      assert cached_cost * 10 <= plain_cost
    end

    test "the warm hit event carries the resource, the action and the store" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read_one(CountedWidget, :get_by_name, %{name: "w"})
      discard_counts()

      AshCache.read_one(CountedWidget, :get_by_name, %{name: "w"})

      assert_received {:ash_cache, :hit,
                       %{resource: CountedWidget, action: :get_by_name, store: :ash_cache}}
    end
  end

  describe "the same result as Ash" do
    test "read_one on a get_by action returns exactly what Ash.read_one returns" do
      create!(CachedWidget, %{name: "w"})

      plain =
        CachedWidget |> Ash.Query.for_read(:get_by_name, %{name: "w"}) |> Ash.read_one()

      cold = AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})
      warm = AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})

      assert cold == plain
      assert warm == plain
    end

    test "read on a list action returns exactly what Ash.read returns" do
      create!(CachedWidget, %{name: "a"})
      create!(CachedWidget, %{name: "b"})

      plain = CachedWidget |> Ash.Query.for_read(:read) |> Ash.read()
      cold = AshCache.read(CachedWidget, :read)
      warm = AshCache.read(CachedWidget, :read)

      assert sorted(cold) == sorted(plain)
      assert warm == cold
    end

    test "a paged read returns exactly the page Ash.read returns" do
      for name <- ~w(a b c), do: create!(CachedWidget, %{name: name})
      page_opts = [page: [limit: 2, offset: 1]]

      plain = CachedWidget |> Ash.Query.for_read(:paged, %{}) |> Ash.read(page_opts)
      cold = AshCache.read(CachedWidget, :paged, %{}, page_opts)
      warm = AshCache.read(CachedWidget, :paged, %{}, page_opts)

      assert {:ok, %Ash.Page.Offset{}} = cold
      assert page_names(cold) == page_names(plain)
      assert warm == cold
    end

    test "a read_one that finds nothing returns nil like Ash.read_one" do
      assert AshCache.read_one(CachedWidget, :get_by_name, %{name: "missing"}) == {:ok, nil}
    end
  end

  describe "clearing" do
    test "a create is seen by the very next call" do
      create!(CachedWidget, %{name: "a"})
      AshCache.read(CachedWidget, :read)

      create!(CachedWidget, %{name: "b"})

      assert names(AshCache.read(CachedWidget, :read)) == ["a", "b"]
    end

    test "an update is seen by the very next call" do
      widget = create!(CachedWidget, %{name: "w", quantity: 1})
      AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})

      widget |> Ash.Changeset.for_update(:update, %{quantity: 2}) |> Ash.update!()

      assert {:ok, %{quantity: 2}} = AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})
    end

    test "a destroy is seen by the very next call" do
      widget = create!(CachedWidget, %{name: "w"})
      AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})

      Ash.destroy!(widget)

      assert AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"}) == {:ok, nil}
    end

    test "AshCache.invalidate/1 makes the next call run the action" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read(CountedWidget, :read)
      discard_counts()

      AshCache.invalidate(CountedWidget)
      AshCache.read(CountedWidget, :read)

      assert count(:policy_checked) == 1
    end

    test "a write to a resource in clear_when_changed makes the next call read again" do
      create!(Post, %{name: "p"})
      AshCache.read(Post, :read)
      discard_counts()

      create!(Comment, %{name: "c"})
      AshCache.read(Post, :read)

      assert Events.drain_for(Post) == [:miss]
    end

    test "an expired entry makes the next call run the action" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read(CountedWidget, :read)
      discard_counts()

      expire_call_entries()
      AshCache.read(CountedWidget, :read)

      assert count(:policy_checked) == 1
    end

    test "the entry lives as long as the read's own ttl" do
      create!(CountedWidget, %{name: "w"})
      before_ms = System.monotonic_time(:millisecond)
      AshCache.read(CountedWidget, :read)
      after_ms = System.monotonic_time(:millisecond)
      ttl = to_timeout(minute: 7)

      assert [expires_at] = call_entry_expiries()
      assert expires_at in (before_ms + ttl)..(after_ms + ttl)
    end
  end

  describe "entries are never shared between" do
    test "different actors" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 1})
      discard_counts()

      AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 2})

      assert count(:policy_checked) == 1
    end

    test "one actor whose attributes changed" do
      create!(CountedWidget, %{name: "w"})
      AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 1, role: :admin})
      discard_counts()

      AshCache.read(CountedWidget, :read, %{}, actor: %User{id: 1, role: :guest})

      assert count(:policy_checked) == 1
    end

    test "different params" do
      create!(CachedWidget, %{name: "a"})
      create!(CachedWidget, %{name: "b"})

      assert {:ok, %{name: "a"}} = AshCache.read_one(CachedWidget, :get_by_name, %{name: "a"})
      assert {:ok, %{name: "b"}} = AshCache.read_one(CachedWidget, :get_by_name, %{name: "b"})
    end

    test "different loads" do
      create!(CachedWidget, %{name: "w", quantity: 3})
      AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"})

      assert {:ok, %{doubled: 6}} =
               AshCache.read_one(CachedWidget, :get_by_name, %{name: "w"}, load: [:doubled])
    end

    test "different tenants" do
      create!(TenantWidget, %{name: "a"}, tenant: "one")
      create!(TenantWidget, %{name: "b"}, tenant: "two")

      assert names(AshCache.read(TenantWidget, :read, %{}, tenant: "one")) == ["a"]
      assert names(AshCache.read(TenantWidget, :read, %{}, tenant: "two")) == ["b"]
    end
  end

  describe "authorization" do
    test "an actor the policy refuses sees nothing cold" do
      create!(GuardedWidget, %{name: "w"})

      assert AshCache.read(GuardedWidget, :read, %{}, actor: nil) == {:ok, []}
    end

    test "regression: an actor the policy refuses sees nothing after an allowed actor warmed the entry" do
      create!(GuardedWidget, %{name: "w"})

      assert names(AshCache.read(GuardedWidget, :read, %{}, actor: %User{id: 1})) == ["w"]
      assert names(AshCache.read(GuardedWidget, :read, %{}, actor: %User{id: 1})) == ["w"]
      assert AshCache.read(GuardedWidget, :read, %{}, actor: nil) == {:ok, []}
    end
  end

  describe "what is stored" do
    test "an empty result is not stored by default" do
      assert AshCache.read(CachedWidget, :read) == {:ok, []}
      assert call_entries() == []
    end

    test "an empty result is stored when the read has cache_empty?: true" do
      assert AshCache.read_one(PartiallyCachedWidget, :get_by_name, %{name: "none"}) ==
               {:ok, nil}

      assert [_entry] = call_entries()
    end

    test "an error is not stored" do
      create!(CachedWidget, %{name: "a"})
      create!(CachedWidget, %{name: "b"})

      assert {:error, _reason} = AshCache.read_one(CachedWidget, :read)
      assert call_entries() == []
    end

    test "an invalid call is not stored" do
      assert {:error, _reason} = AshCache.read_one(CachedWidget, :get_by_name, %{})
      assert call_entries() == []
    end

    test "a bypassed call is neither answered nor stored" do
      create!(CountedWidget, %{name: "w"})
      bypass = [context: %{ash_cache: :bypass}]
      AshCache.read(CountedWidget, :read, %{}, bypass)
      discard_counts()

      assert names(AshCache.read(CountedWidget, :read, %{}, bypass)) == ["w"]
      assert count(:policy_checked) == 1
      assert call_entries() == []
      assert Events.drain() == []
    end
  end

  describe "misuse" do
    test "a read missing from the cache block raises ArgumentError" do
      assert_raise ArgumentError, ~r/:read.*not.*cache/s, fn ->
        AshCache.read(PartiallyCachedWidget, :read)
      end
    end

    test "a resource without the extension raises ArgumentError" do
      assert_raise ArgumentError, ~r/AshCache.Resource/, fn ->
        AshCache.read_one(Widget, :get_by_name, %{name: "w"})
      end
    end
  end

  defp names({:ok, records}), do: records |> Enum.map(& &1.name) |> Enum.sort()

  defp sorted({:ok, records}), do: {:ok, Enum.sort_by(records, & &1.name)}

  defp page_names({:ok, page}), do: Enum.map(page.results, & &1.name)
end
