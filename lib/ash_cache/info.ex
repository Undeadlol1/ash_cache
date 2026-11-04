defmodule AshCache.Info do
  @moduledoc """
  Read a resource's `cache do ... end` configuration.

  `Spark.InfoGenerator` supplies `cache_store/1` (returning `{:ok, value}` or
  `:error`), `cache_store!/1`, and `cache/1`, which lists the section's
  `AshCache.CachedRead`, `AshCache.CachedAction` and `AshCache.RecacheAfterWrite` entities.
  """

  use Spark.InfoGenerator, extension: AshCache.Resource, sections: [:cache]

  @doc "Whether the resource has AshCache configured at all."
  @spec cached?(module()) :: boolean()
  def cached?(resource) do
    AshCache.Resource in Spark.extensions(resource)
  end
end
