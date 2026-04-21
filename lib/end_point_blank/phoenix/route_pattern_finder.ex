defmodule EndPointBlank.Phoenix.RoutePatternFinder do
  @moduledoc """
  Resolves the route pattern (e.g. `/books/:id`) for a live request.

  Uses `phoenix_router` from `conn.private` to match the actual request path
  against the router's compiled route table, returning the pattern string so
  Intake can do an exact match against registered endpoints.
  """

  @doc """
  Returns the matching route pattern for `conn`, or `conn.request_path` as
  a fallback when no pattern match is found.
  """
  def find(%Plug.Conn{} = conn, router) do
    method = conn.method
    path_info = conn.path_info

    router.__routes__()
    |> Enum.find_value(fn route ->
      verb = route.verb |> Atom.to_string() |> String.upcase()

      if verb == method && matches?(route.path, path_info) do
        route.path
      end
    end)
    |> case do
      nil -> conn.request_path
      pattern -> pattern
    end
  end

  defp matches?(pattern, path_info) do
    parts = String.split(pattern, "/", trim: true)

    length(parts) == length(path_info) &&
      Enum.zip(parts, path_info)
      |> Enum.all?(fn {pat, actual} ->
        String.starts_with?(pat, ":") || pat == actual
      end)
  end
end
