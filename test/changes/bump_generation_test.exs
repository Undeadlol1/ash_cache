defmodule AshCache.Changes.BumpGenerationTest do
  use ExUnit.Case, async: true

  alias AshCache.Changes.BumpGeneration
  alias AshCache.Generation
  alias AshCache.Test.Widget

  setup do
    store = :"bump_generation_store_#{System.unique_integer([:positive])}"
    {:ok, store: store, opts: [store: store]}
  end

  defp changeset_with_change(opts) do
    Widget
    |> Ash.Changeset.for_create(:create, %{name: "a"})
    |> BumpGeneration.change(opts, %{})
  end

  defp complete_transaction(changeset, result) do
    [hook] = changeset.after_transaction
    hook.(changeset, result)
  end

  test "registers exactly one after_transaction hook", %{opts: opts} do
    changeset = changeset_with_change(opts)

    assert length(changeset.after_transaction) == 1
    assert changeset.after_action == []
  end

  test "a committed write bumps the resource generation", %{store: store, opts: opts} do
    changeset = changeset_with_change(opts)

    result = {:ok, %{name: "a"}}
    assert complete_transaction(changeset, result) == result
    refute Generation.current(store, Widget) == 0
  end

  test "a failed write does not bump the generation", %{store: store, opts: opts} do
    changeset = changeset_with_change(opts)

    result = {:error, :boom}
    assert complete_transaction(changeset, result) == result
    assert Generation.current(store, Widget) == 0
  end

  describe "warm-after-write (through real actions)" do
    alias AshCache.Test.Events
    alias AshCache.Test.WarmedWidget

    setup do
      AshCache.Testing.capture_events()
    end

    defp wipe_data_layer! do
      {:ok, _table} = Ash.DataLayer.Ets.stop(WarmedWidget)
      Process.delete({:ash_ets_table, WarmedWidget, nil})
    end

    defp get_by_name!(name) do
      WarmedWidget
      |> Ash.Query.for_read(:get_by_name, %{name: name})
      |> Ash.read!()
    end

    test "a create warms the declared read before anyone asks" do
      WarmedWidget
      |> Ash.Changeset.for_create(:create, %{name: "warmed", value: 7})
      |> Ash.create!()

      wipe_data_layer!()

      assert [%{value: 7}] = get_by_name!("warmed")
    end

    test "an update warms the read with the fresh value" do
      widget =
        WarmedWidget
        |> Ash.Changeset.for_create(:create, %{name: "warmed", value: 1})
        |> Ash.create!()

      widget
      |> Ash.Changeset.for_update(:update, %{value: 2})
      |> Ash.update!()

      wipe_data_layer!()

      assert [%{value: 2}] = get_by_name!("warmed")
    end

    defmodule ExplodingActor do
      @moduledoc false
      def resolve, do: raise("actor resolution blew up")
    end

    defp write_result_after_warming(warm) do
      record = %{name: "resilient", value: 3}

      changeset =
        Widget
        |> Ash.Changeset.for_create(:create, record)
        |> BumpGeneration.change([store: :ash_cache, warm: [warm]], %{})

      [hook] = changeset.after_transaction

      hook.(changeset, {:ok, record})
    end

    test "a warm that raises does not fail the already-committed write" do
      exploding_warm = %AshCache.Warm{
        read: :get_by_name,
        args: [name: :name],
        actor: {ExplodingActor, :resolve, []}
      }

      assert {:ok, %{value: 3}} = write_result_after_warming(exploding_warm)
    end

    test "a warm whose read is rejected does not fail the committed write" do
      unknown_read_warm = %AshCache.Warm{read: :no_such_read, args: [name: :name], actor: nil}

      assert {:ok, %{value: 3}} = write_result_after_warming(unknown_read_warm)
    end

    test "a destroy does not warm a read for the dead record" do
      widget =
        WarmedWidget
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
