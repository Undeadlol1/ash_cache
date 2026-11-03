defmodule AshCache.Key do
  @moduledoc """
  Builds deterministic cache keys for cached read and generic actions.

  A key is a plain Erlang term (no hashing, so no collision risk) built from:

    * the resource module
    * the resource's current cache version (see `AshCache.CacheVersion`)
    * the action name
    * the whole query shape — arguments, `filter`, `sort`, `limit`, `offset`,
      `page`, `distinct`, `select`, `load`, `calculations` and
      `aggregates` (assembled in
      `AshCache.Preparations.ReadThrough`). `filter` is the load-bearing one:
      the policy authorizer has already folded its filter checks into it by
      the time the key is derived, so it is what stops an unauthorized read
      from being answered by an authorized one — not merely what tells two
      queries apart
    * for a generic action, only its arguments take the place of the query
      shape (`AshCache.Actions.RunThrough`)
    * for a calculation, `{:calculation, name}` takes the place of the
      action name, and the shape is one record's attributes, the fields the
      calculation loads and its arguments
      (`AshCache.Calculations.CalculateThrough`); there is no version
    * the actor and tenant, so cached results never leak across actors
      or tenants
  """

  @type t ::
          {:ash_cache, resource :: module(), version :: term(), action :: atom(),
           query_shape :: term(), actor_ref :: term(), tenant_ref :: term()}

  @spec build(module(), atom() | {:calculation, atom()}, map(), term(), keyword()) :: t()
  def build(resource, action_name, query_shape, version, opts) do
    {:ash_cache, resource, version, action_name, normalize(query_shape),
     actor_ref(Keyword.get(opts, :actor)), tenant_ref(Keyword.get(opts, :tenant))}
  end

  defp normalize(%_struct{} = value), do: value

  defp normalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, normalize(nested)} end)
    |> Enum.sort()
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value), do: value

  defp actor_ref(nil), do: :no_actor
  defp actor_ref(%struct{id: id}) when not is_nil(id), do: {struct, id}
  defp actor_ref(actor), do: {:actor_term, normalize(actor)}

  defp tenant_ref(nil), do: :no_tenant
  defp tenant_ref(tenant), do: {:tenant, normalize(tenant)}
end
