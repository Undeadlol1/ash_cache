defmodule AshCache.GenericActionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshCache.Test.Events
  alias AshCache.Test.ExchangeRate

  @actor %{id: "alice"}

  setup do
    AshCache.Testing.capture_events()
  end

  defp rates(currency, opts \\ []) do
    ExchangeRate
    |> Ash.ActionInput.for_action(
      :rates,
      %{currency: currency},
      Keyword.put_new(opts, :actor, @actor)
    )
    |> Ash.run_action()
  end

  defp runs do
    receive do
      {:rates_ran, currency} -> [currency | runs()]
    after
      0 -> []
    end
  end

  test "the second identical call is answered from the cache without running the action" do
    assert {:ok, [1.5]} = rates("EUR")
    assert {:ok, [1.5]} = rates("EUR")

    assert runs() == ["EUR"]
    assert Events.drain() == [:miss, :hit]
  end

  test "hit and miss events name the resource, action and store" do
    rates("EUR")
    rates("EUR")

    assert_received {:ash_cache, :miss,
                     %{resource: ExchangeRate, action: :rates, store: :ash_cache, error: nil}}

    assert_received {:ash_cache, :hit,
                     %{resource: ExchangeRate, action: :rates, store: :ash_cache}}
  end

  test "different arguments never share an entry" do
    rates("EUR")
    rates("USD")

    assert runs() == ["EUR", "USD"]
  end

  test "different actors never share an entry" do
    rates("EUR", actor: %{id: "alice"})
    rates("EUR", actor: %{id: "bob"})

    assert runs() == ["EUR", "EUR"]
  end

  test "different tenants never share an entry" do
    rates("EUR", tenant: "a")
    rates("EUR", tenant: "b")
    rates("EUR", tenant: "a")

    assert runs() == ["EUR", "EUR"]
  end

  test "a bypassed call runs the action and emits nothing" do
    rates("EUR")
    Events.drain()

    {:ok, [1.5]} =
      ExchangeRate
      |> Ash.ActionInput.for_action(:rates, %{currency: "EUR"}, actor: @actor)
      |> Ash.ActionInput.set_context(%{ash_cache: :bypass})
      |> Ash.run_action()

    {:ok, [1.5]} = rates("EUR", context: %{ash_cache: :bypass})

    assert runs() == ["EUR", "EUR", "EUR"]
    assert Events.drain() == []
  end

  test "an expired entry runs the action again" do
    rates("EUR")

    for {{:ash_cache_entry, :ash_cache, _key} = entry_key, {value, _expires_at}} <- Process.get() do
      Process.put(entry_key, {value, System.monotonic_time(:millisecond) - 1})
    end

    rates("EUR")

    assert runs() == ["EUR", "EUR"]
  end

  test "AshCache.invalidate/1 throws the cached results away" do
    rates("EUR")
    :ok = AshCache.invalidate(ExchangeRate)
    rates("EUR")

    assert runs() == ["EUR", "EUR"]
  end

  test "an error is returned and not cached" do
    assert {:error, _error} = rates("FAIL")
    assert {:error, _error} = rates("FAIL")

    assert runs() == ["FAIL", "FAIL"]
  end

  test "an empty list is not cached" do
    assert {:ok, []} = rates("NONE")
    assert {:ok, []} = rates("NONE")

    assert runs() == ["NONE", "NONE"]
  end

  test "nil is not cached" do
    assert {:ok, nil} = rates("NIL")
    assert {:ok, nil} = rates("NIL")

    assert runs() == ["NIL", "NIL"]
  end

  test "authorization still runs on a hit" do
    {:ok, [1.5]} = rates("EUR", actor: @actor)

    assert {:error, %Ash.Error.Forbidden{}} = rates("EUR", actor: nil)
    assert runs() == ["EUR"]
  end

  # Spark reports a verifier error as a compile warning on stderr, so
  # `assert_raise` around the compile never sees it.
  describe "compile-time checks" do
    test "a Reactor action is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("""
               action :rates, {:array, :float} do
                 argument :currency, :string
                 run AshCache.Test.RateReactor
               end
               """)
             end) =~ "Reactor"
    end

    test "an action that returns nothing is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("""
               action :rates do
                 run fn _input, _context -> :ok end
               end
               """)
             end) =~ "returns nothing"
    end

    test "naming a read action is rejected" do
      assert capture_io(:stderr, fn ->
               compile_resource("read :rates")
             end) =~ "not generic actions"
    end
  end

  defp compile_resource(action_body) do
    name = "AshCache.Test.CompiledAction#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        extensions: [AshCache.Resource],
        validate_domain_inclusion?: false

      cache do
        action :rates, ttl: 1000
      end

      actions do
        #{action_body}
      end
    end
    """)
  end
end
