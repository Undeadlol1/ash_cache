defmodule AshCache.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(AshCache.Coalesce.child_specs(),
      strategy: :one_for_one,
      name: AshCache.Application.Supervisor
    )
  end
end
