defmodule EndPointBlank.Phoenix.EndpointRegistrar do
  @moduledoc """
  Introspects a Phoenix router at application startup and registers all
  endpoints with the EndPointBlank API.

  Call `register/1` from your OTP application's `start/2`, after calling
  `EndPointBlank.configure/1`:

      def start(_type, _args) do
        EndPointBlank.configure(...)
        EndPointBlank.Phoenix.EndpointRegistrar.register(MyAppWeb.Router)
        children = [MyAppWeb.Endpoint]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
  """

  require Logger
  alias EndPointBlank.Commands.EndpointUpdate

  @doc """
  Reads all routes from `router`, enriches them with any version metadata
  declared via `EndPointBlank.Phoenix.Versioned`, and calls
  `EndPointBlank.Commands.EndpointUpdate.update/1`.
  """
  def register(router) when is_atom(router) do
    endpoints = build_endpoints(router)
    EndpointUpdate.update(endpoints)
  end

  defp build_endpoints(router) do
    router.__routes__()
    |> Enum.map(fn route ->
      controller = route.plug
      action = route.plug_opts
      path = route.path
      verb = route.verb |> Atom.to_string() |> String.upcase()

      %{
        path: path,
        http_method: verb,
        endpoint_versions: controller_versions(controller, action)
      }
    end)
    |> Enum.uniq()
  end

  # Returns a map of `state_name => [versions]` for the given controller+action,
  # matching the shape the other client libraries send. Empty map when the
  # controller has no version metadata.
  defp controller_versions(controller, action) do
    # Force the controller to load before introspection — function_exported?/3
    # returns false for unloaded modules, which would otherwise drop every
    # version metadata when this is invoked during application start.
    Code.ensure_loaded(controller)

    if function_exported?(controller, :__epb_versions__, 0) do
      versions_map = controller.__epb_versions__()

      case Map.get(versions_map, action) do
        states_map when is_map(states_map) and map_size(states_map) > 0 -> states_map
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end
end
