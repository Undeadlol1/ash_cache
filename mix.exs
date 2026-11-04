defmodule AshCache.MixProject do
  use Mix.Project

  @source_url "https://github.com/Undeadlol1/ash_cache"
  @version "0.1.0"

  def project do
    [
      app: :ash_cache,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      docs: &docs/0,
      description: description(),
      package: package(),
      name: "AshCache",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AshCache.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.32"},
      {:spark, "~> 2.3"},
      {:cachex, "~> 3.6", optional: true},
      {:telemetry, "~> 1.2"},
      # Only for `AshCache.Store.Adapters.Nebulex`; apps that use it add
      # Nebulex and the adapters they want themselves.
      {:nebulex, "~> 3.1", optional: true},
      {:nebulex_local, "~> 3.1", only: :test},
      {:nebulex_distributed, "~> 3.3", only: :test},
      # Ash needs a SAT solver to evaluate policies; the suite has resources
      # with policies, so it is a test-only dependency here rather than
      # something this package imposes on its users.
      {:picosat_elixir, "~> 0.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Only for `mix spark.cheat_sheets`, which generates the DSL reference.
      {:igniter, "~> 0.6", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshCache.Resource",
      docs: ["spark.cheat_sheets", "docs"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/examples.md",
        "documentation/topics/clearing.md",
        "documentation/topics/how-it-works.md",
        "documentation/topics/storage.md",
        "documentation/topics/testing.md",
        {"documentation/dsls/DSL-AshCache.Resource.md",
         search_data: Spark.Docs.search_data_for(AshCache.Resource)},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r"documentation/topics",
        Reference: ~r"documentation/dsls",
        "About AshCache": ["CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Public API": [AshCache, AshCache.Resource, AshCache.Supervisor, AshCache.Testing],
        Configuration: [AshCache.Info, AshCache.Refresh],
        "How it works": [
          AshCache.Key,
          AshCache.CacheVersion,
          AshCache.Coalesce,
          AshCache.Dependencies,
          AshCache.Preparations.ReadThrough,
          AshCache.Actions.RunThrough,
          AshCache.Changes.InvalidateCache,
          AshCache.Resource.Transformers.AttachCacheHooks,
          AshCache.Resource.Verifiers.ValidateCacheBlock
        ],
        Storage: [
          AshCache.Store,
          AshCache.Store.Adapter,
          AshCache.Store.Adapters.Cachex,
          AshCache.Store.Adapters.Nebulex,
          AshCache.Store.Adapters.ProcessLocal,
          AshCache.Store.Adapters.Noop
        ]
      ]
    ]
  end

  defp description do
    "Declarative read-through caching for Ash resources, with version-based invalidation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib documentation .formatter.exs mix.exs README.md CHANGELOG.md LICENSE usage-rules.md)
    ]
  end
end
