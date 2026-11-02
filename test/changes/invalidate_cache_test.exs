defmodule AshCache.Changes.InvalidateCacheTest do
  use ExUnit.Case, async: true

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

    write_result = {:ok, %{name: "a"}}
    assert complete_transaction(changeset, write_result) == write_result
    refute CacheVersion.current(store, Widget) == 0
  end

  test "a failed write does not bump the cache version", %{store: store, opts: opts} do
    changeset = changeset_with_bump(opts)

    write_result = {:error, :boom}
    assert complete_transaction(changeset, write_result) == write_result
    assert CacheVersion.current(store, Widget) == 0
  end

  describe "refreshing after a write, through real actions" do
    alias AshCache.Test.Events
    alias AshCache.Test.RefreshedWidget

    setup do
      AshCache.Testing.capture_events()
    end

    defp wipe_data_layer! do
      {:ok, _table} = Ash.DataLayer.Ets.stop(RefreshedWidget)
      Process.delete({:ash_ets_table, RefreshedWidget, nil})
    end

    defp get_by_name!(name) do
      RefreshedWidget
      |> Ash.Query.for_read(:get_by_name, %{name: name})
      |> Ash.read!()
    end

    test "a create refreshes the declared read before anyone asks" do
      RefreshedWidget
      |> Ash.Changeset.for_create(:create, %{name: "refreshed", quantity: 7})
      |> Ash.create!()

      wipe_data_layer!()

      assert [%{quantity: 7}] = get_by_name!("refreshed")
    end

    test "an update refreshes the read with the fresh value" do
      widget =
        RefreshedWidget
        |> Ash.Changeset.for_create(:create, %{name: "refreshed", quantity: 1})
        |> Ash.create!()

      widget
      |> Ash.Changeset.for_update(:update, %{quantity: 2})
      |> Ash.update!()

      wipe_data_layer!()

      assert [%{quantity: 2}] = get_by_name!("refreshed")
    end

    defmodule ExplodingActor do
      @moduledoc false
      def resolve, do: raise("actor resolution blew up")
    end

    defp write_result_after_refreshing(refresh) do
      record = %{name: "resilient", quantity: 3}

      changeset =
        Widget
        |> Ash.Changeset.for_create(:create, record)
        |> InvalidateCache.change([store: :ash_cache, refresh: [refresh]], %{})

      [hook] = changeset.after_transaction

      hook.(changeset, {:ok, record})
    end

    test "a refresh that raises does not fail the already-committed write" do
      exploding_refresh = %AshCache.Refresh{
        read: :get_by_name,
        arguments: [name: :name],
        actor: {ExplodingActor, :resolve, []}
      }

      assert {:ok, %{quantity: 3}} = write_result_after_refreshing(exploding_refresh)
    end

    test "a refresh whose read is rejected does not fail the committed write" do
      unknown_read_refresh = %AshCache.Refresh{
        read: :no_such_read,
        arguments: [name: :name],
        actor: nil
      }

      assert {:ok, %{quantity: 3}} = write_result_after_refreshing(unknown_read_refresh)
    end

    test "a destroy does not refresh a read for the dead record" do
      widget =
        RefreshedWidget
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
