defmodule EndPointBlank.VersionFinder do
  @moduledoc """
  Detects the API version for an incoming request.

  Priority order (same as the Ruby, JS, and Java libraries):
    1. Custom `config.version_finder` function
    2. `Accept` header (vendor MIME type)
    3. `X-Api-Version` header
    4. `Content-Type` header (vendor MIME type)
    5. `version` query parameter
    6. Path segment (e.g. `/v1/`)
  """

  @accept_re ~r/application\/vnd\.\w+\.v(\d+)/i
  @x_api_re ~r/v?(\d+)/i
  @path_re ~r/\/v(\d+)\//i

  @doc "Returns the version string for the request, or nil if not detected."
  def find(%Plug.Conn{} = conn) do
    config = EndPointBlank.Config.get()

    if config.version_finder do
      config.version_finder.(conn)
    else
      detect(conn)
    end
  end

  defp detect(conn) do
    accept = first_header(conn, "accept")
    x_api = first_header(conn, "x-api-version")
    content_type = first_header(conn, "content-type")
    query_v =
      case conn.query_params do
        %Plug.Conn.Unfetched{} -> nil
        qp -> qp["version"]
      end

    cond do
      v = extract(@accept_re, accept) -> v
      v = extract(@x_api_re, x_api) -> v
      v = extract(@accept_re, content_type) -> v
      v = extract_query(query_v) -> v
      v = extract(@path_re, conn.request_path) -> v
      true -> nil
    end
  end

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [val | _] -> val
      [] -> nil
    end
  end

  defp extract(_re, nil), do: nil

  defp extract(re, str) do
    case Regex.run(re, str) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp extract_query(nil), do: nil

  defp extract_query(v) do
    case Regex.run(@x_api_re, v) do
      [_, n] -> n
      _ -> nil
    end
  end
end
