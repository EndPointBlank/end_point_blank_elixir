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

  describe "intake_header/0 and intake_header!/0 (sc-1469)" do
    test "is the well-formed Basic header when both credentials are set" do
      assert Authorization.intake_header() == {:ok, "Basic " <> Base.encode64("cid:csecret")}
      assert Authorization.intake_header!() == "Basic " <> Base.encode64("cid:csecret")
      assert Authorization.missing_credentials() == []
    end

    test "refuses, rather than answering Basic Og==, when either is nil or empty" do
      for {missing, keys} <- [
            {[client_id: ""], [:client_id]},
            {[client_secret: ""], [:client_secret]},
            {[client_id: "", client_secret: ""], [:client_id, :client_secret]}
          ] do
        Config.update(client_id: "cid", client_secret: "csecret")
        Config.update(missing)

        assert Authorization.intake_header() == {:error, :missing_credentials}
        assert Authorization.missing_credentials() == keys

        error =
          assert_raise EndPointBlank.ConfigurationError, fn -> Authorization.intake_header!() end

        assert error.missing == keys
        refute error.message =~ "cid"
      end

      assert Authorization.missing_credentials_message() =~
               "EndPointBlank is missing client_id and client_secret: "
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
        assert {:error, {:unexpected, _raised}} = Authorization.header(base_url)
      end)

      assert Process.whereis(EndPointBlank.AccessTokens) |> Process.alive?()
      assert_only_intake_was_called()

      # A raise is not intake's verdict on this URL, so it is not recorded as
      # one (sc-1469): last_failure/1 must not send anyone to check the network.
      assert AccessTokens.last_failure(base_url) == nil
    end

    test "refuses without a request when client_id or client_secret is missing",
         %{base_url: base_url} do
      # Sending it anyway would go out as Basic of ":" and come back as a 401,
      # reported as "re-issue the credential" for what is a missing setting.
      stub_intake_and_provider(fn conn -> respond(conn, 401) end)

      for {missing, names} <- [
            {[client_id: ""], "client_id"},
            {[client_secret: ""], "client_secret"},
            {[client_id: "", client_secret: ""], "client_id and client_secret"}
          ] do
        Config.update(client_id: "cid", client_secret: "csecret")
        Config.update(missing)

        log =
          capture_log(fn ->
            assert Authorization.header(base_url) == {:error, :missing_credentials}
          end)

        assert log =~ "Access token not requested: EndPointBlank is missing #{names}: "
      end

      refute_received {:intake, _path, _auth}
      refute_received {:provider, _auth}
      assert AccessTokens.last_failure(base_url) == nil
    end

    test "strips userinfo, query and fragment before asking intake for a token",
         %{base_url: base_url} do
      # intake refuses a base_url carrying any of them (422), and any of them
      # can carry a secret, so they are never sent.
      test_pid = self()

      stub_intake_and_provider(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:mint_body, body})
        mint_echoing(conn, "minted-token", body["base_url"])
      end)

      raw = String.replace(base_url, "https://", "https://user:hunter2@") <> "/orders?k=s3cret#f"

      assert Authorization.header(raw) == {:ok, "Bearer minted-token"}
      assert_received {:mint_body, %{"base_url" => sent}}
      assert sent == base_url <> "/orders"
    end

    test "refuses an unparseable URL without asking intake for anything" do
      stub_intake_and_provider(fn conn -> mint(conn, "should-not-be-minted") end)

      for bad <- ["not a url ?token=s3cret", "/orders/1", "https://", "mailto:a@b.test"] do
        assert Authorization.header(bad) == {:error, :invalid_base_url}
      end

      refute_received {:intake, _path, _auth}
      refute_received {:provider, _auth}
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
      assert error.status == 401
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
      assert error.status == nil
      assert error.message =~ "access token for (no URL): "
    end

    test "keeps the raw transport error on :reason but describes it in fixed words",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      {error, _log} =
        with_log(fn ->
          assert_raise TokenUnavailableError, fn -> Authorization.header!(base_url) end
        end)

      assert {:transport_error, %Req.TransportError{reason: :timeout}} = error.reason
      assert error.status == nil
      assert error.unexpected == false
      assert error.message =~ "intake could not be reached (timeout, connection refused"
      refute error.message =~ "Req.TransportError"

      assert_only_intake_was_called()
    end

    test "does not put a raise from minting into the message", %{base_url: base_url} do
      stub_intake_and_provider(fn _conn -> raise "intake exploded with csecret" end)

      {error, _log} =
        with_log(fn ->
          assert_raise TokenUnavailableError, fn -> Authorization.header!(base_url) end
        end)

      assert {:unexpected, %RuntimeError{}} = error.reason
      assert error.unexpected == true
      assert error.status == nil
      assert error.message =~ "the token request failed unexpectedly"
      refute error.message =~ "exploded"
      refute error.message =~ "csecret"
      refute error.message =~ "RuntimeError"
    end

    test "keeps only the stripped URL on the exception", %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> respond(conn, 401) end)
      raw = String.replace(base_url, "https://", "https://user:hunter2@") <> "/orders?k=s3cret#f"

      {error, _log} =
        with_log(fn ->
          assert_raise TokenUnavailableError, fn -> Authorization.header!(raw) end
        end)

      assert error.base_url == base_url <> "/orders"
      assert error.message =~ "access token for #{base_url}/orders: "

      for secret <- ~w(hunter2 s3cret) do
        refute error.message =~ secret
      end
    end

    test "raises ConfigurationError, not TokenUnavailableError, when a credential is missing",
         %{base_url: base_url} do
      stub_intake_and_provider(fn conn -> respond(conn, 401) end)
      Config.update(client_secret: "")

      {error, _log} =
        with_log(fn ->
          assert_raise EndPointBlank.ConfigurationError, fn -> Authorization.header!(base_url) end
        end)

      assert error.missing == [:client_secret]

      assert error.message ==
               "EndPointBlank is missing client_secret: set it with EndPointBlank.configure/1 " <>
                 "or ENDPOINTBLANK_CLIENT_ID / ENDPOINTBLANK_CLIENT_SECRET. The SDK cannot " <>
                 "authenticate to its intake without both."

      refute error.message =~ "re-issue"
      refute_received {:intake, _path, _auth}
      refute_received {:provider, _auth}
    end

    test "raises TokenUnavailableError for an unparseable URL, keeping no URL" do
      bad = "not a url ?token=s3cret"
      error = assert_raise TokenUnavailableError, fn -> Authorization.header!(bad) end

      assert error.reason == :invalid_base_url
      assert error.base_url == nil
      refute error.message =~ "s3cret"
    end
  end

  describe "TokenUnavailableError" do
    test "explains every reason and always states the no-credentials rule" do
      for reason <- [
            :missing_base_url,
            :invalid_base_url,
            :token_cache_unavailable,
            :invalid_token,
            :credential_rejected,
            {:request_rejected, 422},
            {:server_error, 503},
            {:transport_error, %Req.TransportError{reason: :timeout}},
            {:unexpected, %RuntimeError{message: "boom"}},
            :missing_credentials,
            nil
          ] do
        message = TokenUnavailableError.message("https://api.example.test/orders", reason)

        assert message =~ "https://api.example.test/orders"
        assert message =~ "there is no Basic-auth fallback"
      end

      assert TokenUnavailableError.message("u", {:transport_error, :timeout}) =~
               "intake could not be reached (timeout, connection refused or retries exhausted)"

      assert TokenUnavailableError.message("u", :credential_rejected) =~ "re-issue the credential"
    end

    test "writes the URL plainly, in the documented wording" do
      assert TokenUnavailableError.message(
               "https://api.example.test/orders",
               {:transport_error, %Req.TransportError{reason: :econnrefused}}
             ) ==
               "Could not mint an EndPointBlank access token for " <>
                 "https://api.example.test/orders: intake could not be reached " <>
                 "(timeout, connection refused or retries exhausted); this may be " <>
                 "transient. EndPointBlank never sends this service's " <>
                 "client_id/client_secret to a provider, so there is no " <>
                 "Basic-auth fallback and the call must not be made without a token."
    end

    test "never inspects an unknown transport error term into the message" do
      reason = {:transport_error, %{request: %{headers: [{"authorization", "Basic c2VjcmV0"}]}}}

      error = TokenUnavailableError.exception(base_url: "https://api.test", reason: reason)

      assert error.reason == reason
      assert error.message =~ "the token request failed unexpectedly"
      refute error.message =~ "c2VjcmV0"
      refute error.message =~ "authorization"
      refute error.message =~ "%{"

      for other <- [{:transport_error, {:exit, "s3cr3t"}}, {:weird, "s3cr3t"}, "s3cr3t"] do
        refute TokenUnavailableError.message("u", other) =~ "s3cr3t"
      end
    end

    test "marks a mint that failed unexpectedly, and nothing else" do
      for {reason, unexpected} <- [
            {{:unexpected, %RuntimeError{message: "boom"}}, true},
            {{:unexpected, {:throw, :boom}}, true},
            {{:transport_error, %{request: :not_a_transport_error}}, true},
            {{:transport_error, %Req.TransportError{reason: :timeout}}, false},
            {{:transport_error, :econnrefused}, false},
            {:credential_rejected, false},
            {{:server_error, 503}, false},
            {:missing_credentials, false},
            {nil, false}
          ] do
        assert TokenUnavailableError.unexpected?(reason) == unexpected

        error = TokenUnavailableError.exception(base_url: "https://a.test", reason: reason)
        assert error.unexpected == unexpected
      end
    end

    test "does not describe a URL that is not a string" do
      message = TokenUnavailableError.message(%{secret: "s3cr3t"}, :missing_base_url)

      assert message =~ "access token for (no URL): "
      refute message =~ "s3cr3t"
    end

    test "derives :status from the reason" do
      for {reason, status} <- [
            {:credential_rejected, 401},
            {{:request_rejected, 422}, 422},
            {{:server_error, 503}, 503},
            {{:transport_error, %Req.TransportError{reason: :timeout}}, nil},
            {{:transport_error, :econnrefused}, nil},
            {:token_cache_unavailable, nil},
            {:invalid_token, nil},
            {{:unexpected, %RuntimeError{message: "boom"}}, nil},
            {:missing_credentials, nil},
            {:missing_base_url, nil},
            {nil, nil}
          ] do
        assert TokenUnavailableError.status(reason) == status

        error = TokenUnavailableError.exception(base_url: "https://a.test", reason: reason)
        assert error.status == status
      end
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
    mint_echoing(conn, token, Jason.decode!(raw)["base_url"])
  end

  defp mint_echoing(conn, token, base_url) do
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
