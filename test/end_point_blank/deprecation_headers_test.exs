defmodule EndPointBlank.DeprecationHeadersTest do
  @moduledoc """
  The vectors below are the shared set from app_portal's
  `docs/superpowers/specs/2026-08-01-header-vectors.md`. The same table is
  asserted in every SDK, so an Elixir date format that differs from Ruby's by a
  leading zero is a test failure here rather than a subtly non-compliant header
  a customer finds.

  Row 1 is RFC 9745's own worked example. It is the reason to trust the rest.
  """
  use ExUnit.Case, async: true

  alias EndPointBlank.DeprecationHeaders

  @vectors [
    {"2023-06-30T23:59:59Z", "@1688169599", "Fri, 30 Jun 2023 23:59:59 GMT"},
    {"2026-01-01T00:00:00Z", "@1767225600", "Thu, 01 Jan 2026 00:00:00 GMT"},
    {"2026-03-09T05:00:00Z", "@1773032400", "Mon, 09 Mar 2026 05:00:00 GMT"},
    {"2026-08-01T14:15:16Z", "@1785593716", "Sat, 01 Aug 2026 14:15:16 GMT"},
    {"2026-11-11T11:11:11Z", "@1794395471", "Wed, 11 Nov 2026 11:11:11 GMT"}
  ]

  defp headers(block), do: block |> DeprecationHeaders.build() |> Map.new()

  describe "the shared vectors" do
    for {iso, deprecation, sunset} <- @vectors do
      test "formats #{iso}" do
        result = headers(%{"deprecated_at" => unquote(iso), "sunset_at" => unquote(iso)})

        assert result["deprecation"] == unquote(deprecation)
        assert result["sunset"] == unquote(sunset)
      end
    end
  end

  describe "RFC conformance details" do
    test "zero-pads the day of month" do
      assert headers(%{"sunset_at" => "2026-01-01T00:00:00Z"})["sunset"] =~ " 01 Jan "
    end

    test "always says GMT, never UTC or an offset" do
      sunset = headers(%{"sunset_at" => "2026-01-01T00:00:00Z"})["sunset"]

      assert String.ends_with?(sunset, " GMT")
      refute sunset =~ "UTC"
      refute sunset =~ "+00"
    end

    test "converts a non-UTC input rather than relabelling it" do
      # 2026-01-01T00:00:00+02:00 is 2025-12-31T22:00:00Z.
      assert headers(%{"sunset_at" => "2026-01-01T00:00:00+02:00"})["sunset"] ==
               "Wed, 31 Dec 2025 22:00:00 GMT"
    end

    test "emits the deprecation value unquoted and without sub-second precision" do
      assert headers(%{"deprecated_at" => "2023-06-30T23:59:59.750Z"})["deprecation"] ==
               "@1688169599"
    end

    test "header names are lowercase, which Plug requires and HTTP/2 mandates" do
      names =
        %{"deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => "2026-11-11T11:11:11Z"}
        |> DeprecationHeaders.build()
        |> Enum.map(&elem(&1, 0))

      assert names == ["deprecation", "sunset"]
      # put_resp_header/3 raises on an uppercase name, so this is not cosmetic.
      assert Enum.all?(names, &(&1 == String.downcase(&1)))
    end
  end

  describe "partial and absent input" do
    test "emits deprecation alone when there is no sunset date" do
      # The normal starting state: going away, no deadline committed yet.
      result = headers(%{"deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => nil})

      assert Map.has_key?(result, "deprecation")
      refute Map.has_key?(result, "sunset")
    end

    test "returns nothing for nil or an empty block" do
      assert DeprecationHeaders.build(nil) == []
      assert DeprecationHeaders.build(%{}) == []
    end
  end

  describe "never producing a plausible header from nonsense" do
    test "ignores an integer" do
      # An integer is readable as a Unix timestamp; accepting one would turn a
      # nonsense value into a header that looks right and is wrong.
      assert DeprecationHeaders.build(%{"deprecated_at" => 12_345}) == []
    end

    test "ignores a malformed timestamp" do
      assert DeprecationHeaders.build(%{"deprecated_at" => "not a date"}) == []
    end

    test "ignores a non-map block" do
      assert DeprecationHeaders.build("nonsense") == []
      assert DeprecationHeaders.build([1, 2, 3]) == []
    end

    test "still emits the good half when only one timestamp is bad" do
      result = headers(%{"deprecated_at" => "2026-01-01T00:00:00Z", "sunset_at" => "garbage"})

      assert result["deprecation"] == "@1767225600"
      refute Map.has_key?(result, "sunset")
    end
  end

  describe "put_headers/2" do
    setup do
      %{conn: Plug.Test.conn(:get, "/things")}
    end

    test "sets both headers on the conn", %{conn: conn} do
      conn =
        DeprecationHeaders.put_headers(conn, %{
          "deprecated_at" => "2026-01-01T00:00:00Z",
          "sunset_at" => "2026-11-11T11:11:11Z"
        })

      assert Plug.Conn.get_resp_header(conn, "deprecation") == ["@1767225600"]
      assert Plug.Conn.get_resp_header(conn, "sunset") == ["Wed, 11 Nov 2026 11:11:11 GMT"]
    end

    test "sets nothing when there is no deprecation", %{conn: conn} do
      conn = DeprecationHeaders.put_headers(conn, nil)

      assert Plug.Conn.get_resp_header(conn, "deprecation") == []
      assert Plug.Conn.get_resp_header(conn, "sunset") == []
    end

    test "does not override a header the application already set", %{conn: conn} do
      # An app that sets its own Sunset has said something more specific than we
      # know about that particular response.
      conn = Plug.Conn.put_resp_header(conn, "sunset", "Mon, 01 Jan 2035 00:00:00 GMT")
      conn = DeprecationHeaders.put_headers(conn, %{"sunset_at" => "2026-11-11T11:11:11Z"})

      assert Plug.Conn.get_resp_header(conn, "sunset") == ["Mon, 01 Jan 2035 00:00:00 GMT"]
    end

    test "returns the conn unchanged rather than raising on nonsense", %{conn: conn} do
      assert DeprecationHeaders.put_headers(conn, %{"deprecated_at" => :not_a_date}) == conn
    end
  end
end
