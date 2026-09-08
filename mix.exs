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
      docs: docs(),
      description: description(),
      package: package(),
      name: "AshCache",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.32"},
      {:spark, "~> 2.3"},
      {:cachex, "~> 3.6"},
      # Ash needs a SAT solver to evaluate policies; the suite has resources
      # with policies, so it is a test-only dependency here rather than
      # something this package imposes on its users.
      {:picosat_elixir, "~> 0.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
  end

  defp description do
    "Declarative read-through caching for Ash resources, with generation-based invalidation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
