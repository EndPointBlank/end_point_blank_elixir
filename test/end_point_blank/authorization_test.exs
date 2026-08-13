defmodule EndPointBlank.AuthorizationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, Authorization, Config}

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

    # Each test uses its own base_url, so a leftover entry from another test
    # cannot be served here instead of a fresh mint.
    AccessTokens.clear()

    on_exit(fn ->
      Config.reset()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    %{base_url: "https://host-#{System.unique_integer([:positive])}.test"}
  end

  # Echoes the request's base_url back as the resolved one -- correct for
  # every test here, since none of them straddle a path-prefix boundary.
  defp stub_minting(token) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      base_url = Jason.decode!(raw)["base_url"]

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => token, "expired_at" => expires_at, "base_url" => base_url})
    end)
  end

  defp cache_token(base_url, token) do
    stub_minting(token)
    AccessTokens.token(base_url)
  end

  describe "basic_credentials/0" do
    test "base64-encodes the configured client id and secret" do
      assert Authorization.basic_credentials() == Base.encode64("cid:csecret")
    end

    test "reflects a credential change without needing a restart" do
      Config.update(client_id: "rotated", client_secret: "rotated-secret")

      assert Authorization.basic_credentials() == Base.encode64("rotated:rotated-secret")
    end
  end

  describe "basic_header/0" do
    test "is a well-formed HTTP Basic header" do
      assert Authorization.basic_header() == "Basic " <> Base.encode64("cid:csecret")
    end
  end

  describe "header/1" do
    test "mints a token when no usable entry is held", %{base_url: base_url} do
      # The whole point of the header: nothing else mints the first token, so if
      # this asked whether one already existed instead of asking for one, the
      # answer would be no forever and every call would go out on the long-lived
      # client credentials.
      stub_minting("minted-token")

      assert Authorization.header(base_url) == "Bearer minted-token"
    end

    test "falls back to Basic when a token cannot be minted", %{base_url: base_url} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      assert capture_log(fn ->
               assert Authorization.header(base_url) == Authorization.basic_header()
             end) =~ "GenerateAccessToken failed"
    end

    test "falls back to Basic rather than raising when minting blows up", %{base_url: base_url} do
      # Req raises rather than returning an error for some misconfigurations.
      # Minting runs inside the AccessTokens GenServer, so an unhandled raise
      # there would restart it, and enough restarts would take the host
      # application's supervision tree down with the SDK's.
      Req.Test.stub(__MODULE__.Stub, fn _conn -> raise "intake exploded" end)

      capture_log(fn ->
        assert Authorization.header(base_url) == Authorization.basic_header()
      end)

      assert Process.whereis(EndPointBlank.AccessTokens) |> Process.alive?()
    end

    test "falls back to Basic when no base_url is given" do
      # Log writers have no target base URL, so this is the ordinary path for
      # them -- not an edge case.
      assert Authorization.header() == Authorization.basic_header()
    end

    test "falls back to Basic when base_url is an empty string" do
      assert Authorization.header("") == Authorization.basic_header()
    end

    test "prefers the held token", %{base_url: base_url} do
      cache_token(base_url, "cached-token")

      assert Authorization.header(base_url) == "Bearer cached-token"
    end

    test "does not offer one target's token for a different target", %{base_url: base_url} do
      # The whole reason the cache is a map: intake binds a token to the
      # application environment its request resolved to, and a service that
      # calls two targets needs a token for each. Confusing them would present
      # the wrong credential to the second target.
      other = "https://other-" <> String.trim_leading(base_url, "https://")
      cache_token(base_url, "token-a")
      cache_token(other, "token-b")

      assert Authorization.header(base_url) == "Bearer token-a"
      assert Authorization.header(other) == "Bearer token-b"
    end
  end
end
