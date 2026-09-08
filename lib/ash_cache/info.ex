defmodule AshCache.Info do
  @moduledoc """
  Read a resource's `cache do ... end` configuration.

  `Spark.InfoGenerator` supplies the per-option readers — `cache_ttl/1`,
  `cache_store/1`, `cache_reads/1`, `cache_adapter_options/1` (each returning
  `{:ok, value}` or `:error`, plus raising `!` variants) and the predicate
  `cache_cache_empty?/1`.
  """

  use Spark.InfoGenerator, extension: AshCache.Resource, sections: [:cache]

  @doc "Whether the resource has AshCache configured at all."
  @spec cached?(module()) :: boolean()
  def cached?(resource) do
    AshCache.Resource in Spark.extensions(resource)
  end
end
