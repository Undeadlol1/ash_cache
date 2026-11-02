defmodule AshCache.Resource.Transformers.AttachCacheHooksTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshCache.Changes.BumpGeneration
  alias AshCache.Preparations.ReadThrough
  alias AshCache.Resource.Transformers.AttachCacheHooks
  alias AshCache.Test.BlockTtlWidget
  alias AshCache.Test.CachedWidget
  alias AshCache.Test.DefaultTtlWidget
  alias AshCache.Test.Events
  alias AshCache.Test.InfiniteBlockWidget
  alias AshCache.Test.InfiniteReadWidget
  alias AshCache.Test.PartiallyCachedWidget
  alias AshCache.Test.TwoTtlWidget
  alias Spark.Dsl.Extension

  defp read_through_opts(resource, action_name) do
    action = Info.action(resource, action_name)

    Enum.find_value(action.preparations, fn
      %{preparation: {ReadThrough, opts}} -> opts
      _other -> nil
    end)
  end

  defp bump_generation_opts(resource, action_name) do
    action = Info.action(resource, action_name)

    Enum.find_value(action.changes, fn
      %{change: {BumpGeneration, opts}} -> opts
      _other -> nil
    end)
  end

  describe "transformer contract" do
    test "runs after every other transformer, so action defaults already exist" do
      assert AttachCacheHooks.after?(Ash.Resource.Dsl)
    end

    test "transform returns an updated dsl state" do
      assert {:ok, _dsl_state} =
               AttachCacheHooks.transform(CachedWidget.spark_dsl_config())
    end

    test "caching the primary read suppresses Ash's primary-read warning" do
      refute Extension.get_persisted(CachedWidget, :primary_read_warning?)
    end

    test "a narrowed config that skips the primary read keeps Ash's warning armed" do
      assert Extension.get_persisted(PartiallyCachedWidget, :primary_read_warning?)
    end
  end

  describe "plain read declarations" do
    test "every declared read gets the read-through preparation with defaults" do
      for action_name <- [:read, :get_by_name] do
        opts = read_through_opts(CachedWidget, action_name)

        assert opts[:store] == :ash_cache
        assert opts[:ttl] == to_timeout(hour: 1)
        assert opts[:cache_empty?] == false
        assert opts[:adapter_options] == []
      end
    end

    test "existing preparations on an action are kept" do
      action = Info.action(CachedWidget, :get_by_name)

      attached_preparations = Enum.map(action.preparations, & &1.preparation)
      assert Enum.any?(attached_preparations, &match?({Ash.Resource.Preparation.Build, _}, &1))
      assert Enum.any?(attached_preparations, &match?({ReadThrough, _}, &1))
    end

    test "every write action gets the bump-generation change" do
      for action_name <- [:create, :update, :destroy] do
        assert bump_generation_opts(CachedWidget, action_name) == [store: :ash_cache]
      end
    end
  end

  describe "narrowed configuration" do
    test "only the listed read actions are cached" do
      assert read_through_opts(PartiallyCachedWidget, :read) == nil

      opts = read_through_opts(PartiallyCachedWidget, :get_by_name)
      assert opts[:store] == :partial_store
      assert opts[:ttl] == to_timeout(minute: 5)
      assert opts[:cache_empty?] == true
    end

    test "each read gets its own ttl, and an undeclared read gets none" do
      assert read_through_opts(TwoTtlWidget, :get_by_name)[:ttl] == to_timeout(hour: 1)
      assert read_through_opts(TwoTtlWidget, :paged)[:ttl] == to_timeout(minute: 1)
      assert read_through_opts(TwoTtlWidget, :read) == nil
    end

    test "write actions are still invalidated even when reads are narrowed" do
      for action_name <- [:create, :update, :destroy] do
        assert bump_generation_opts(PartiallyCachedWidget, action_name) ==
                 [store: :partial_store]
      end
    end
  end

  describe "which ttl a read gets" do
    setup do
      AshCache.Testing.capture_events()
    end

    defp expiry_times_after_two_reads(resource) do
      resource
      |> Ash.Changeset.for_create(:create, %{name: "w", quantity: 1})
      |> Ash.create!()

      read = fn -> resource |> Ash.Query.for_read(:get_by_name, %{name: "w"}) |> Ash.read!() end
      read.()
      read.()

      for {{:ash_cache_entry, :ash_cache, _key}, {[_ | _], expires_at}} <- Process.get(),
          do: expires_at
    end

    test "no ttl anywhere falls back to five minutes" do
      assert read_through_opts(DefaultTtlWidget, :get_by_name)[:ttl] == 300_000
    end

    test "a read inherits the block ttl and its own ttl wins" do
      assert read_through_opts(BlockTtlWidget, :get_by_name)[:ttl] == to_timeout(minute: 2)
      assert read_through_opts(BlockTtlWidget, :paged)[:ttl] == to_timeout(second: 10)
    end

    test "an :infinity block ttl is inherited and the entry never expires" do
      assert read_through_opts(InfiniteBlockWidget, :get_by_name)[:ttl] == :infinity
      assert expiry_times_after_two_reads(InfiniteBlockWidget) == [:infinity]
      assert Enum.reject(Events.drain(), &(&1 == :invalidate)) == [:miss, :hit]
    end

    test "an :infinity read ttl beats a finite block ttl and the entry never expires" do
      assert read_through_opts(InfiniteReadWidget, :get_by_name)[:ttl] == :infinity
      assert expiry_times_after_two_reads(InfiniteReadWidget) == [:infinity]
    end
  end
end
