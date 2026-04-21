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
    |> Enum.flat_map(fn route ->
      controller = route.plug
      action = route.plug_opts
      path = route.path
      verb = route.verb |> Atom.to_string() |> String.upcase()

      versions = controller_versions(controller, action)

      Enum.map(versions, fn {version, state} ->
        %{
          path: path,
          http_method: verb,
          version: version,
          state: state
        }
      end)
    end)
    |> Enum.uniq()
  end

  # Returns a list of {version, state} tuples for the given controller+action.
  # Falls back to [{nil, "Current"}] when the controller has no version metadata.
  defp controller_versions(controller, action) do
    if function_exported?(controller, :__epb_versions__, 0) do
      versions_map = controller.__epb_versions__()

      case Map.get(versions_map, action) do
        %{versions: versions, state: state} ->
          Enum.map(versions, fn v -> {v, state} end)

        nil ->
          [{nil, "Current"}]
      end
    else
      [{nil, "Current"}]
    end
  rescue
    _ -> [{nil, "Current"}]
  end
end
