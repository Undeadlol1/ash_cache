# Boots the suite for lib/ash_cache's own standalone mix project. The host
# app never loads this file: it runs test/test_helper.exs, and Mix loads a
# test_helper only from the root of a configured test path.
Application.put_env(:ash_cache, :adapter, AshCache.Store.Adapters.ProcessLocal)

{:ok, _} =
  Supervisor.start_link([{AshCache.Supervisor, domains: [AshCache.Test.Domain]}],
    strategy: :one_for_one
  )

ExUnit.start()
