defmodule EndPointBlank.AuthorizationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, Authorization, Config, TokenUnavailableError}

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

  describe "header/1 -- outbound calls to a provider (sc-1469)" do
    test "mints a token when no usable entry is held", %{base_url: base_url} do
      # Nothing else mints the first token, so if this asked whether one already
      # existed instead of asking for one, the answer would be no forever.
      stub_minting("minted-token")

      assert Authorization.header(base_url) == {:ok, "Bearer minted-token"}
    end

    test "prefers the held token", %{base_url: base_url} do
      cache_token(base_url, "cached-token")

      assert Authorization.header(base_url) == {:ok, "Bearer cached-token"}
    end

    test "does not offer one target's token for a different target", %{base_url: base_url} do
      # intake binds a token to the application environment its request
      # resolved to, and a service that calls two targets needs a token for
      # each. Confusing them would present the wrong credential to the second.
      other = "https://other-" <> String.trim_leading(base_url, "https://")
      cache_token(base_url, "token-a")
      cache_token(other, "token-b")

      assert Authorization.header(base_url) == {:ok, "Bearer token-a"}
      assert Authorization.header(other) == {:ok, "Bearer token-b"}
    end

    test "the provider receives the Bearer token", %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> mint(conn, "minted-token") end)

      assert {:ok, %Req.Response{status: 200}} = call_provider(base_url <> "/orders")
      assert_received {:provider, "Bearer minted-token"}
    end

    test "refuses, rather than falling back to Basic, when intake answers 5xx",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> respond(conn, 500) end)

      capture_log(fn ->
        assert Authorization.header(base_url) == {:error, {:server_error, 500}}
        assert call_provider(base_url <> "/orders") == {:error, {:server_error, 500}}
      end)

      assert_only_intake_was_called()
    end

    test "refuses, rather than falling back to Basic, when the credential is rejected (401)",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> respond(conn, 401) end)

      capture_log(fn ->
        assert Authorization.header(base_url) == {:error, :credential_rejected}
        assert call_provider(base_url <> "/orders") == {:error, :credential_rejected}
      end)

      assert_only_intake_was_called()
    end

    test "refuses, rather than falling back to Basic, when intake times out",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      capture_log(fn ->
        assert {:error, {:transport_error, %Req.TransportError{reason: :timeout}}} =
                 Authorization.header(base_url)

        assert {:error, {:transport_error, _}} = call_provider(base_url <> "/orders")
      end)

      assert_only_intake_was_called()
    end

    test "refuses rather than raising when minting blows up", %{base_url: base_url} do
      # Minting runs inside the AccessTokens GenServer, so an unhandled raise
      # there would restart it, and enough restarts would take the host
      # application's supervision tree down with the SDK's.
      stub_intake_and_provider(fn _conn -> raise "intake exploded" end)

      capture_log(fn ->
        assert {:error, {:transport_error, _}} = Authorization.header(base_url)
      end)

      assert Process.whereis(EndPointBlank.AccessTokens) |> Process.alive?()
      assert_only_intake_was_called()
    end

    test "refuses a missing or empty URL without asking intake for anything" do
      stub_intake_and_provider(fn conn -> mint(conn, "should-not-be-minted") end)

      assert Authorization.header(nil) == {:error, :missing_base_url}
      assert Authorization.header("") == {:error, :missing_base_url}
      assert Authorization.header(:not_a_url) == {:error, :missing_base_url}

      refute_received {:intake, _path, _auth}
      refute_received {:provider, _auth}
    end

    test "has no no-argument form" do
      # header/0 used to answer Basic unconditionally. Its removal is the point:
      # a call site that still uses it must fail to compile, not quietly go on
      # sending the credential to a provider.
      Code.ensure_loaded!(Authorization)

      refute function_exported?(Authorization, :header, 0)
      refute function_exported?(Authorization, :header!, 0)
    end
  end

  describe "header!/1" do
    test "returns the Bearer header value", %{base_url: base_url} do
      stub_minting("minted-token")

      assert Authorization.header!(base_url) == "Bearer minted-token"
    end

    test "raises TokenUnavailableError naming the reason when no token can be minted",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> respond(conn, 401) end)

      {error, _log} =
        with_log(fn ->
          assert_raise TokenUnavailableError, fn -> Authorization.header!(base_url) end
        end)

      assert error.base_url == base_url
      assert error.reason == :credential_rejected
      assert error.message =~ "Could not mint an EndPointBlank access token"
      assert error.message =~ "401"
      assert error.message =~ "never sends this service's client_id/client_secret"
      refute error.message =~ "csecret"
      refute error.message =~ Base.encode64("cid:csecret")

      assert_only_intake_was_called()
    end

    test "raises TokenUnavailableError for a missing URL" do
      error = assert_raise TokenUnavailableError, fn -> Authorization.header!(nil) end

      assert error.reason == :missing_base_url
    end
  end

  describe "TokenUnavailableError" do
    test "explains every reason and always states the no-credentials rule" do
      for reason <- [
            :missing_base_url,
            :token_cache_unavailable,
            :credential_rejected,
            {:request_rejected, 422},
            {:server_error, 503},
            {:transport_error, %Req.TransportError{reason: :timeout}},
            nil
          ] do
        message = TokenUnavailableError.message("https://api.example.test/orders", reason)

        assert message =~ "https://api.example.test/orders"
        assert message =~ "there is no Basic-auth fallback"
      end

      assert TokenUnavailableError.message("u", {:transport_error, :timeout}) =~ "timeout"
      assert TokenUnavailableError.message("u", :credential_rejected) =~ "re-issued"
    end
  end

  # Routes the stub by host: intake's own host gets `intake_fun`, anything else
  # is "the provider" and records the Authorization header it was sent.
  defp stub_intake_and_provider(intake_fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

      if conn.host == "intake.test" do
        send(test_pid, {:intake, conn.request_path, auth})
        intake_fun.(conn)
      else
        send(test_pid, {:provider, auth})
        Req.Test.json(conn, %{"ok" => true})
      end
    end)
  end

  defp mint(conn, token) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    base_url = Jason.decode!(raw)["base_url"]
    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    conn
    |> Plug.Conn.put_status(201)
    |> Req.Test.json(%{"token" => token, "expired_at" => expires_at, "base_url" => base_url})
  end

  defp respond(conn, status) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "nope"})
  end

  # What a host application's outbound call looks like: get the header, and
  # only make the call if there is one.
  defp call_provider(url) do
    with {:ok, auth} <- Authorization.header(url) do
      Req.get(url, headers: [{"authorization", auth}], plug: {Req.Test, __MODULE__.Stub})
    end
  end

  # Every request that went out was the token mint to intake -- which is this
  # SDK's own intake and legitimately carries Basic -- and not one reached the
  # provider, with Basic or anything else.
  defp assert_only_intake_was_called do
    assert_received {:intake, "/api/access_token", _auth}
    refute_received {:provider, _auth}
  end
end
