defmodule AshCache.Domain do
  @moduledoc """
  Makes a domain's code-interface functions for cached reads answer from the
  cache, like the resource's own functions do.

      defmodule MyApp.Shop do
        use Ash.Domain
        use AshCache.Domain

        resources do
          resource MyApp.Shop.Product do
            define :get_product_by_sku, action: :get_by_sku, args: [:sku]
          end
        end
      end

  `use AshCache.Domain` must come after `use Ash.Domain`.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile AshCache.Domain
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:spark_dsl_config, 0}) do
      raise ArgumentError, "`use AshCache.Domain` must come after `use Ash.Domain`"
    end

    interfaces =
      for reference <- Ash.Domain.Info.resource_references(env.module),
          interface <- reference.definitions,
          do: {reference.resource, interface}

    AshCache.CodeInterface.wrap(env, interfaces)
  end
end
