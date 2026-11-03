defmodule AshCache.CalculationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshCache.Test.Events
  alias AshCache.Test.Parcel
  alias AshCache.Test.Shipment

  setup do
    AshCache.Testing.capture_events()
  end

  defp shipment(name, attrs \\ %{}) do
    Shipment
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :name, name))
    |> Ash.create!()
  end

  defp parcel(shipment, name) do
    Parcel
    |> Ash.Changeset.for_create(:create, %{name: name, shipment_id: shipment.id})
    |> Ash.create!()
  end

  defp update(shipment, attrs) do
    shipment |> Ash.Changeset.for_update(:update, attrs) |> Ash.update!()
  end

  defp quote_of(records, opts \\ []) do
    {load, opts} = Keyword.pop(opts, :load, :quote)
    name = with [{name, _args}] <- load, do: name
    records |> Ash.load!(load, opts) |> value_of(name)
  end

  defp value_of(records, name) when is_list(records), do: Enum.map(records, &value_of(&1, name))
  defp value_of(record, name), do: Map.fetch!(record, name)

  # Each real run of the calculation reports the names of the records it got.
  defp runs do
    receive do
      {:calculated, names} -> [names | runs()]
    after
      0 -> []
    end
  end

  defp clear_events_and_runs do
    Events.drain()
    runs()
  end

  test "the second load is answered from the cache without running the calculation" do
    box = shipment("box", %{quantity: 2})
    clear_events_and_runs()

    assert quote_of(box) == "box:2:0:"
    assert quote_of(box) == "box:2:0:"

    assert runs() == [["box"]]
    assert Events.drain() == [:miss, :hit]
  end

  test "hit and miss events name the resource, calculation and store" do
    box = shipment("box")
    clear_events_and_runs()
    quote_of(box)
    quote_of(box)

    assert_received {:ash_cache, :miss,
                     %{resource: Shipment, calculation: :quote, store: :ash_cache}}

    assert_received {:ash_cache, :hit,
                     %{resource: Shipment, calculation: :quote, store: :ash_cache}}
  end

  test "a batch runs the calculation only for the records not cached, in their order" do
    [a, b, c, d] = Enum.map(~w[a b c d], &shipment/1)
    quote_of([b, d])
    clear_events_and_runs()

    assert quote_of([a, b, c, d]) == ["a:1:0:", "b:1:0:", "c:1:0:", "d:1:0:"]
    assert runs() == [["a", "c"]]
    assert Events.drain() == [:miss, :hit, :miss, :hit]
  end

  test "a batch fully in the cache does not run the calculation" do
    records = Enum.map(~w[a b], &shipment/1)
    quote_of(records)
    clear_events_and_runs()

    assert quote_of(records) == ["a:1:0:", "b:1:0:"]
    assert runs() == []
  end

  test "different arguments never share an entry" do
    box = shipment("box", %{quantity: 2})

    assert quote_of(box, load: [quote: %{rate: 3}]) == "box:6:0:"
    assert quote_of(box, load: [quote: %{rate: 5}]) == "box:10:0:"
    assert quote_of(box, load: [quote: %{rate: 3}]) == "box:6:0:"

    assert runs() == [["box"], ["box"]]
  end

  test "changing an attribute the calculation reads runs it again" do
    box = shipment("box")
    quote_of(box)

    assert box |> update(%{quantity: 4}) |> quote_of() == "box:4:0:"
    assert runs() == [["box"], ["box"]]
  end

  # The cache cannot know which attributes a calculation reads, so every
  # attribute is part of the key.
  test "changing an attribute the calculation does not read also runs it again" do
    box = shipment("box")
    quote_of(box)

    assert box |> update(%{note: "fragile"}) |> quote_of() == "box:1:0:"
    assert runs() == [["box"], ["box"]]
  end

  test "a change to a related record the calculation loads runs it again" do
    box = shipment("box")
    lid = parcel(box, "lid")
    assert quote_of(box) == "box:1:1:lid"

    lid |> Ash.Changeset.for_update(:update, %{name: "cap"}) |> Ash.update!()

    assert quote_of(box) == "box:1:1:cap"
    assert runs() == [["box"], ["box"]]
  end

  test "a change to an aggregate the calculation loads runs it again" do
    box = shipment("box")
    quote_of(box)
    parcel(box, "lid")

    assert quote_of(box) == "box:1:1:lid"
    assert runs() == [["box"], ["box"]]
  end

  test "a nil result is cached" do
    record = shipment("nil")

    assert quote_of(record) == nil
    assert quote_of(record) == nil
    assert runs() == [["nil"]]
  end

  test "an empty list result is cached" do
    record = shipment("none")

    assert quote_of(record) == []
    assert quote_of(record) == []
    assert runs() == [["none"]]
  end

  test "an error is returned and not cached" do
    record = shipment("fail")

    assert {:error, _error} = Ash.load(record, :quote)
    assert {:error, _error} = Ash.load(record, :quote)
    assert runs() == [["fail"], ["fail"]]
  end

  test "a bypassed load runs the calculation and emits nothing" do
    box = shipment("box")
    quote_of(box)
    clear_events_and_runs()

    assert quote_of(box, context: %{ash_cache: :bypass}) == "box:1:0:"

    assert runs() == [["box"]]
    assert Events.drain() == []
  end

  test "different actors never share an entry" do
    box = shipment("box")

    quote_of(box, actor: %{id: "alice"})
    quote_of(box, actor: %{id: "bob"})
    quote_of(box, actor: %{id: "alice"})

    assert runs() == [["box"], ["box"]]
  end

  test "different tenants never share an entry" do
    box = shipment("box")

    quote_of(box, tenant: "a")
    quote_of(box, tenant: "b")
    quote_of(box, tenant: "a")

    assert runs() == [["box"], ["box"]]
  end

  test "an expired entry runs the calculation again" do
    box = shipment("box")
    quote_of(box)

    for {{:ash_cache_entry, :ash_cache, _key} = entry_key, {value, _expires_at}} <- Process.get() do
      Process.put(entry_key, {value, System.monotonic_time(:millisecond) - 1})
    end

    quote_of(box)

    assert runs() == [["box"], ["box"]]
  end

  test "an entry lives for the calculation's ttl" do
    box = shipment("box")
    before = System.monotonic_time(:millisecond)
    quote_of(box)

    [expires_at] =
      for {{:ash_cache_entry, :ash_cache, _key}, {{:calculated, _value}, expires_at}} <-
            Process.get(),
          do: expires_at

    assert expires_at >= before + to_timeout(hour: 1)
  end

  test "is cached when loaded by an uncached read" do
    shipment("box")

    for _ <- 1..2 do
      assert [%{quote: "box:1:0:"}] = Shipment |> Ash.Query.load(:quote) |> Ash.read!()
    end

    assert runs() == [["box"]]
  end

  # `:label` loads nothing: a cached read hit that must load an aggregate or
  # relationship never returns (a separate, known problem of cached reads).
  test "is cached when loaded by a cached read" do
    shipment("box")

    for _ <- 1..2 do
      assert [%{label: "box:1"}] =
               Shipment
               |> Ash.Query.for_read(:cached_read)
               |> Ash.Query.load(:label)
               |> Ash.read!()
    end

    assert runs() == [["box"]]
    assert_received {:ash_cache, :hit, %{action: :cached_read}}
    assert_received {:ash_cache, :hit, %{calculation: :label}}
  end

  test "a calculation not in the cache block is never cached" do
    box = shipment("box")
    clear_events_and_runs()

    quote_of(box, load: :uncached_quote)
    quote_of(box, load: :uncached_quote)

    assert runs() == [["box"], ["box"]]
    assert Events.drain() == []
  end

  # Spark reports a verifier error as a compile warning on stderr, so
  # `assert_raise` around the compile never sees it.
  describe "compile-time checks" do
    test "a calculation without its own ttl uses the cache block's ttl" do
      # Compiling a resource with a calculation after protocol consolidation
      # warns; that warning is not under test.
      {module, _warning} = with_io(:stderr, fn -> compile_resource("calculation :quote") end)

      {AshCache.Calculations.CalculateThrough, opts} =
        Ash.Resource.Info.calculation(module, :quote).calculation

      assert opts[:ttl] == to_timeout(minute: 5)
    end

    test "naming a calculation the resource does not have is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("calculation :missing")
             end) =~ "not calculations on this resource"
    end

    test "an expression calculation is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("calculation :doubled")
             end) =~ "already runs in the database"
    end

    test "a calculation declared twice is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("""
               calculation :quote
               calculation :quote
               """)
             end) =~ "declared more than once"
    end
  end

  defp compile_resource(cache_body) do
    name = "AshCache.Test.CompiledCalculation#{System.unique_integer([:positive])}"
    compile_resource(name, cache_body)
    Module.concat([name])
  end

  defp compile_resource(name, cache_body) do
    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        extensions: [AshCache.Resource],
        validate_domain_inclusion?: false

      cache do
        #{cache_body}
      end

      attributes do
        uuid_primary_key :id
        attribute :quantity, :integer
      end

      calculations do
        calculate :quote, :term, AshCache.Test.ShippingQuote
        calculate :doubled, :integer, expr(quantity * 2)
      end
    end
    """)
  end
end
