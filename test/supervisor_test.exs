defmodule AshCache.SupervisorTest do
  use ExUnit.Case, async: true

  alias AshCache.Test.Domain

  test "discovers every distinct store declared by cached resources" do
    assert Enum.sort(AshCache.Supervisor.store_names([Domain])) ==
             [:ash_cache, :partial_store]
  end

  test "starts one store child per discovered store" do
    pid =
      start_supervised!(
        {AshCache.Supervisor, domains: [Domain], name: :ash_cache_supervisor_under_test}
      )

    assert Supervisor.count_children(pid).specs == 2
    assert {:ok, true} = Cachex.put(:partial_store, :probe, 1)
    assert {:ok, 1} = Cachex.get(:partial_store, :probe)
  end

  test "no cached resources means no children" do
    assert AshCache.Supervisor.store_names([]) == []
  end

  test "a store that is already running elsewhere is adopted, not fatal" do
    pid =
      start_supervised!(
        {AshCache.Supervisor, domains: [Domain], name: :ash_cache_supervisor_collision}
      )

    assert AshCache.Supervisor.start_store(:ash_cache) == :ignore
    assert {:ok, true} = Cachex.put(:ash_cache, :probe, 1)
    assert Process.alive?(pid)
  end
end
