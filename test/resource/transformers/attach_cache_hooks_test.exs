defmodule AshCache.Resource.Transformers.AttachCacheHooksTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshCache.Changes.BumpGeneration
  alias AshCache.Preparations.ReadThrough
  alias AshCache.Resource.Transformers.AttachCacheHooks
  alias AshCache.Test.CachedWidget
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

      preparation_refs = Enum.map(action.preparations, & &1.preparation)
      assert Enum.any?(preparation_refs, &match?({Ash.Resource.Preparation.Build, _}, &1))
      assert Enum.any?(preparation_refs, &match?({ReadThrough, _}, &1))
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
end
