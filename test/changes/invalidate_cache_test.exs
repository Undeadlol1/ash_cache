defmodule AshCache.Changes.InvalidateCacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshCache.Changes.InvalidateCache
  alias AshCache.CacheVersion
  alias AshCache.Test.Widget

  setup do
    store = :"invalidate_cache_store_#{System.unique_integer([:positive])}"
    {:ok, store: store, opts: [store: store]}
  end

  defp changeset_with_bump(opts) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: "a"})
    |> InvalidateCache.change(opts, %{})
  end

  defp complete_transaction(changeset, transaction_result) do
    [hook] = changeset.after_transaction
    hook.(changeset, transaction_result)
  end

  test "registers exactly one after-transaction hook", %{opts: opts} do
    changeset = changeset_with_bump(opts)

    assert length(changeset.after_transaction) == 1
    assert changeset.after_action == []
  end

  test "a committed write bumps the resource's cache version", %{store: store, opts: opts} do
    changeset = changeset_with_bump(opts)
    before = CacheVersion.current(store, Widget)

    write_result = {:ok, %{name: "a"}}
    assert complete_transaction(changeset, write_result) == write_result
    refute CacheVersion.current(store, Widget) == before
  end

  test "a failed write does not bump the cache version", %{store: store, opts: opts} do
    changeset = changeset_with_bump(opts)
    before = CacheVersion.current(store, Widget)

    write_result = {:error, :boom}
    assert complete_transaction(changeset, write_result) == write_result
    assert CacheVersion.current(store, Widget) == before
  end

  describe "an app that holds work until its outer transaction commits" do
    defmodule HoldUntilOuterCommit do
      def hold(work), do: send(self(), {:held_until_commit, work})
    end

    setup do
      Process.put(:ash_cache_after_commit, {HoldUntilOuterCommit, :hold})
      on_exit(fn -> Process.delete(:ash_cache_after_commit) end)
    end

    defp complete_write(changeset, record) do
      [hook] = changeset.after_action
      hook.(changeset, record)
    end

    test "registers no after-transaction hook, so nothing runs inside the app's open transaction",
         %{opts: opts} do
      changeset = changeset_with_bump(opts)

      assert changeset.after_transaction == []
      assert length(changeset.after_action) == 1
    end

    test "the cache version is bumped only when the app runs the held work", %{
      store: store,
      opts: opts
    } do
      changeset = changeset_with_bump(opts)
      before = CacheVersion.current(store, Widget)

      assert complete_write(changeset, %{name: "a"}) == {:ok, %{name: "a"}}
      assert CacheVersion.current(store, Widget) == before

      assert_received {:held_until_commit, held_work}
      held_work.()
      refute CacheVersion.current(store, Widget) == before
    end

    test "an outer rollback that drops the held work leaves the cache version as it was",
         %{store: store, opts: opts} do
      changeset = changeset_with_bump(opts)
      before = CacheVersion.current(store, Widget)

      complete_write(changeset, %{name: "a"})
      assert_received {:held_until_commit, _dropped_on_rollback}
      assert CacheVersion.current(store, Widget) == before
    end
  end

  describe "recaching after a write, through real actions" do
    alias AshCache.Test.Events
    alias AshCache.Test.RecachedWidget

    setup do
      AshCache.Testing.capture_events()
    end

    defp wipe_data_layer! do
      {:ok, _table} = Ash.DataLayer.Ets.stop(RecachedWidget)
      Process.delete({:ash_ets_table, RecachedWidget, nil})
    end

    defp get_by_name!(name) do
      RecachedWidget
      |> Ash.Query.for_read(:get_by_name, %{name: name})
      |> Ash.read!()
    end

    test "a create recaches the declared read before anyone asks" do
      RecachedWidget
      |> Ash.Changeset.for_create(:create, %{name: "recached", quantity: 7})
      |> Ash.create!()

      wipe_data_layer!()

      assert [%{quantity: 7}] = get_by_name!("recached")
    end

    test "an update recaches the read with the fresh value" do
      widget =
        RecachedWidget
        |> Ash.Changeset.for_create(:create, %{name: "recached", quantity: 1})
        |> Ash.create!()

      widget
      |> Ash.Changeset.for_update(:update, %{quantity: 2})
      |> Ash.update!()

      wipe_data_layer!()

      assert [%{quantity: 2}] = get_by_name!("recached")
    end

    defmodule ExplodingActor do
      @moduledoc false
      def resolve, do: raise("actor resolution blew up")
    end

    defp write_result_after_recaching(recache) do
      record = %{name: "resilient", quantity: 3}

      changeset =
        Widget
        |> Ash.Changeset.for_create(:create, record)
        |> InvalidateCache.change([store: :ash_cache, recache_after_write: [recache]], %{})

      [hook] = changeset.after_transaction

      hook.(changeset, {:ok, record})
    end

    test "a recache that raises does not fail the already-committed write" do
      exploding_recache = %AshCache.RecacheAfterWrite{
        read: :get_by_name,
        arguments: [name: :name],
        actor: {ExplodingActor, :resolve, []}
      }

      log =
        capture_log(fn ->
          assert {:ok, %{quantity: 3}} = write_result_after_recaching(exploding_recache)
        end)

      assert log =~ "AshCache could not recache"
    end

    test "a recache whose read is rejected does not fail the committed write" do
      unknown_read_recache = %AshCache.RecacheAfterWrite{
        read: :no_such_read,
        arguments: [name: :name],
        actor: nil
      }

      log =
        capture_log(fn ->
          assert {:ok, %{quantity: 3}} = write_result_after_recaching(unknown_read_recache)
        end)

      assert log =~ "AshCache could not recache"
    end

    test "a destroy does not recache a read for the dead record" do
      widget =
        RecachedWidget
        |> Ash.Changeset.for_create(:create, %{name: "doomed"})
        |> Ash.create!()

      assert [_widget] = get_by_name!("doomed")
      assert Events.drain() == [:invalidate, :miss, :hit]

      Ash.destroy!(widget)
      assert Events.drain() == [:invalidate]

      assert [] = get_by_name!("doomed")
      assert Events.drain() == [:miss]
    end
  end
end
