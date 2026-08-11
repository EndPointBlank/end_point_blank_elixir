defmodule EndPointBlank.AuthorizationTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{AccessTokens, Authorization, Config}

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

    on_exit(fn ->
      Config.reset()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    %{hostname: "host-#{System.unique_integer([:positive])}.test"}
  end

  defp cache_token(hostname, token) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => token, "expired_at" => expires_at})
    end)

    AccessTokens.token(hostname)
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
    test "falls back to Basic when no token is cached for the host", %{hostname: hostname} do
      assert Authorization.header(hostname) == Authorization.basic_header()
    end

    test "falls back to Basic when no host is given" do
      # Log writers have no target host, so this is the ordinary path for them —
      # not an edge case.
      assert Authorization.header() == Authorization.basic_header()
    end

    test "prefers the held token", %{hostname: hostname} do
      cache_token(hostname, "cached-token")

      assert Authorization.header(hostname) == "Bearer cached-token"
    end

    test "offers the held token whatever host is named", %{hostname: hostname} do
      # Intake binds a token to the application environment the credential
      # belongs to, not to the hostname the request names, so there is no
      # "another host's token" to withhold — it is this node's one token.
      cache_token(hostname, "cached-token")

      assert Authorization.header("elsewhere." <> hostname) == "Bearer cached-token"
    end
  end
end
