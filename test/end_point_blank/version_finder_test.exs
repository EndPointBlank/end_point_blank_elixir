defmodule EndPointBlank.VersionFinderTest do
  @moduledoc """
  The detected version is part of the authorization decision and of the auth
  cache key, so a change in precedence here silently re-points traffic at a
  different endpoint version. The order is shared with the Ruby, JS and Java
  libraries and is pinned rather than left to whichever source happens to win.
  """
  use ExUnit.Case, async: false

  alias EndPointBlank.{Config, VersionFinder}

  setup do
    Config.reset()
    on_exit(&Config.reset/0)
    :ok
  end

  defp conn(path \\ "/things", headers \\ []) do
    Enum.reduce(headers, Plug.Test.conn(:get, path), fn {name, value}, acc ->
      Plug.Conn.put_req_header(acc, name, value)
    end)
  end

  describe "each source on its own" do
    test "reads a vendor MIME version from Accept" do
      assert VersionFinder.find(conn("/things", [{"accept", "application/vnd.myapp.v2+json"}])) ==
               "2"
    end

    test "reads X-Api-Version with a leading v" do
      assert VersionFinder.find(conn("/things", [{"x-api-version", "v4"}])) == "4"
    end

    test "reads a bare number from X-Api-Version" do
      assert VersionFinder.find(conn("/things", [{"x-api-version", "4"}])) == "4"
    end

    test "reads a vendor MIME version from Content-Type" do
      assert VersionFinder.find(
               conn("/things", [{"content-type", "application/vnd.myapp.v5+json"}])
             ) ==
               "5"
    end

    test "reads the version query parameter" do
      assert VersionFinder.find(Plug.Conn.fetch_query_params(conn("/things?version=6"))) == "6"
    end

    test "reads a version segment from the path" do
      assert VersionFinder.find(conn("/v7/things")) == "7"
    end
  end

  describe "precedence" do
    test "Accept beats every other source" do
      request =
        conn("/v9/things?version=8", [
          {"accept", "application/vnd.myapp.v1+json"},
          {"x-api-version", "2"},
          {"content-type", "application/vnd.myapp.v3+json"}
        ])

      assert VersionFinder.find(Plug.Conn.fetch_query_params(request)) == "1"
    end

    test "X-Api-Version beats Content-Type, the query and the path" do
      request =
        conn("/v9/things?version=8", [
          {"x-api-version", "2"},
          {"content-type", "application/vnd.myapp.v3+json"}
        ])

      assert VersionFinder.find(Plug.Conn.fetch_query_params(request)) == "2"
    end

    test "Content-Type beats the query and the path" do
      request = conn("/v9/things?version=8", [{"content-type", "application/vnd.myapp.v3+json"}])

      assert VersionFinder.find(Plug.Conn.fetch_query_params(request)) == "3"
    end

    test "the query parameter beats the path" do
      request = conn("/v9/things?version=8")

      assert VersionFinder.find(Plug.Conn.fetch_query_params(request)) == "8"
    end
  end

  describe "when no version is expressed" do
    test "returns nil for a plain request" do
      assert VersionFinder.find(conn()) == nil
    end

    test "ignores an Accept header with no vendor version" do
      assert VersionFinder.find(conn("/things", [{"accept", "application/json"}])) == nil
    end

    test "ignores a query parameter holding no digits" do
      assert VersionFinder.find(Plug.Conn.fetch_query_params(conn("/things?version=latest"))) ==
               nil
    end

    test "does not treat a bare path segment as a version" do
      # `/videos/1` must not read as version 1; only a `/vN/` segment counts.
      assert VersionFinder.find(conn("/videos/1")) == nil
    end

    test "does not crash when the query string was never fetched" do
      # ReportInteraction fetches query params, but Plug.Authorized can run in a
      # pipeline that has not, and an unfetched struct is not a map of params.
      assert VersionFinder.find(conn("/things?version=6")) == nil
    end
  end

  describe "a configured version finder" do
    test "replaces the built-in detection entirely" do
      Config.update(version_finder: fn _conn -> "custom" end)

      assert VersionFinder.find(conn("/v1/things", [{"x-api-version", "9"}])) == "custom"
    end

    test "receives the conn so it can use anything on the request" do
      Config.update(version_finder: fn conn -> conn.request_path end)

      assert VersionFinder.find(conn("/tenants/acme")) == "/tenants/acme"
    end
  end
end
