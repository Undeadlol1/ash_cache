defmodule AshCache.DocsTest do
  use ExUnit.Case, async: true

  # `@moduledoc false` drops a module from the generated hexdocs and fails
  # nothing, so the gap first becomes visible to a reader of the released
  # package. Pinning the set makes both halves deliberate: hiding one of
  # these, and publishing a module that was meant to stay internal.
  @published_modules ~w[
    AshCache
    AshCache.CacheVersion
    AshCache.CachedRead
    AshCache.Changes.InvalidateCache
    AshCache.Info
    AshCache.Key
    AshCache.Preparations.ReadThrough
    AshCache.Refresh
    AshCache.Resource
    AshCache.Resource.Transformers.AttachCacheHooks
    AshCache.Resource.Verifiers.ValidateCacheBlock
    AshCache.Store
    AshCache.Store.Adapter
    AshCache.Store.Adapters.Cachex
    AshCache.Store.Adapters.Noop
    AshCache.Store.Adapters.ProcessLocal
    AshCache.Supervisor
    AshCache.Testing
  ]

  @package_root Path.expand("../lib", __DIR__)

  test "hexdocs publishes exactly the modules this package declares" do
    assert documented_modules() == Enum.sort(@published_modules)
  end

  defp documented_modules do
    sources = Path.wildcard(Path.join(@package_root, "**/*.ex"))

    refute sources == [], "no sources found under #{@package_root}"

    sources
    |> Enum.flat_map(&(&1 |> File.read!() |> documented_module()))
    |> Enum.sort()
  end

  defp documented_module(source) do
    with [_, module] <- Regex.run(~r/^defmodule\s+([\w.]+)\s+do$/m, source),
         false <- source =~ ~r/^\s*@moduledoc false$/m do
      [module]
    else
      _ -> []
    end
  end
end
