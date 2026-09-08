defmodule EndPointBlank.Commands.GenerateAccessTokenTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.Config
  alias EndPointBlank.Commands.GenerateAccessToken

  setup do
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
    end)

    :ok
  end

  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:token_request, conn.request_path, Jason.decode!(raw),
         conn |> Plug.Conn.get_req_header("authorization") |> List.first()}
      )

      fun.(conn)
    end)
  end

  test "returns the token document intake issued" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => "abc", "expired_at" => "2030-01-01T00:00:00Z"})
    end)

    assert GenerateAccessToken.generate("https://api.example.com/orders") == %{
             "token" => "abc",
             "expired_at" => "2030-01-01T00:00:00Z"
           }
  end

  test "asks the access-token endpoint for the given base_url and configured TTL" do
    Config.update(token_ttl: 1_800)
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate("https://api.example.com/orders")

    assert_receive {:token_request, path, body, _auth}
    assert path == "/api/access_token"
    assert body == %{"base_url" => "https://api.example.com/orders", "token_ttl" => 1_800}
  end

  test "sends the base_url verbatim, with no normalization" do
    # Intake owns normalization and matches by longest path prefix. The SDK
    # altering the argument -- downcasing, trimming a trailing slash, or
    # reducing it to a hostname -- would change which environment the caller
    # asked for.
    messy = "https://API.Example.com:8443/Orders/"
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate(messy)

    assert_receive {:token_request, _path, body, _auth}
    assert body["base_url"] == messy
  end

  test "authenticates with Basic credentials" do
    # A token request cannot present a token, so this must never try to.
    stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)

    GenerateAccessToken.generate("https://api.example.com/orders")

    assert_receive {:token_request, _path, _body, auth}
    assert auth == "Basic " <> Base.encode64("cid:csecret")
  end

  test "returns nil and logs when intake refuses" do
    stub(fn conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "nope"}) end)

    log =
      capture_log(fn ->
        assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
      end)

    assert log =~ "GenerateAccessToken failed"
    assert log =~ "403"
  end

  test "returns nil and logs when intake cannot be reached" do
    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    log =
      capture_log(fn ->
        assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
      end)

    assert log =~ "GenerateAccessToken error"
  end

  describe "generate_result/1" do
    # intake now answers 401 for a rejected credential and something else for
    # everything else, so the status carries actionable meaning: 401 means stop
    # and re-issue the credential, anything else means the failure may well be
    # gone on the next call. `generate/1` flattens every one of those to `nil`,
    # so a caller holding its return value cannot tell them apart. This is the
    # entry point that keeps the distinction.

    test "returns the parsed document on success" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"token" => "abc", "expired_at" => "2030-01-01T00:00:00Z"})
      end)

      assert GenerateAccessToken.generate_result("https://api.example.com/orders") ==
               {:ok, %{"token" => "abc", "expired_at" => "2030-01-01T00:00:00Z"}}
    end

    test "returns :credential_rejected on 401" do
      # The one permanent failure: the credential itself was refused, and it
      # will go on being refused until a human re-issues it. Retrying is not
      # just useless, it is a login-failure storm against intake.
      stub(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "nope"})
      end)

      log =
        capture_log(fn ->
          assert GenerateAccessToken.generate_result("https://api.example.com/orders") ==
                   {:error, :credential_rejected}
        end)

      # The pre-existing log line is unchanged; nothing about the old
      # observable behaviour is dropped in favour of the new return value.
      assert log =~ "GenerateAccessToken failed"
      assert log =~ "401"
    end

    test "returns {:request_rejected, status} for any other 4xx" do
      # intake's access-token controller answers 400 for an invalid token_ttl
      # or a missing base_url, and 422 for "Missing target application",
      # "Missing source application" or "Failed to create access token".
      # Every one of those is as permanent as a 401 -- retrying is futile --
      # but the remedy is registering the environment or fixing the request,
      # not re-issuing the credential. Filing them under `server_error` would
      # tell a caller to retry something that can never succeed.
      for status <- [400, 403, 404, 422, 429] do
        stub(fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{}) end)

        capture_log(fn ->
          assert GenerateAccessToken.generate_result("https://api.example.com/orders") ==
                   {:error, {:request_rejected, status}}
        end)
      end
    end

    test "returns {:server_error, status} for a 5xx" do
      # The transient bucket: intake fell over, and the identical call may
      # well succeed on the next attempt.
      for status <- [500, 502, 503] do
        stub(fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{}) end)

        capture_log(fn ->
          assert GenerateAccessToken.generate_result("https://api.example.com/orders") ==
                   {:error, {:server_error, status}}
        end)
      end
    end

    test "files an unexpected non-2xx, non-4xx, non-5xx status under server_error" do
      # A 3xx that Req did not follow is a broken server, not a rejected
      # request. It must land somewhere explicit rather than falling through
      # a clause that does not exist.
      stub(fn conn -> conn |> Plug.Conn.put_status(199) |> Req.Test.json(%{}) end)

      capture_log(fn ->
        assert GenerateAccessToken.generate_result("https://api.example.com/orders") ==
                 {:error, {:server_error, 199}}
      end)
    end

    test "returns {:transport_error, reason} when intake cannot be reached" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log =
        capture_log(fn ->
          assert {:error, {:transport_error, %Req.TransportError{reason: :econnrefused}}} =
                   GenerateAccessToken.generate_result("https://api.example.com/orders")
        end)

      assert log =~ "GenerateAccessToken error"
    end
  end

  describe "generate/1 legacy contract" do
    # These are published-library return values. `generate/1` keeps answering
    # exactly what it answered before -- payload-or-nil -- and the status-aware
    # answer arrives alongside it rather than in place of it.

    test "still returns the payload on success and nil on every failure" do
      stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "abc"}) end)
      assert GenerateAccessToken.generate("https://api.example.com/orders") == %{"token" => "abc"}

      for status <- [401, 400, 403, 422, 500] do
        stub(fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{}) end)

        capture_log(fn ->
          assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
        end)
      end

      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      capture_log(fn ->
        assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
      end)
    end

    test "logs exactly what it logged before on a 401" do
      # A 401 used to be indistinguishable from a 500 here, and at this layer
      # it still is: the extra loudness belongs to AccessTokens, which knows
      # the failure is about to cost callers their tokens.
      stub(fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end)

      log =
        capture_log(fn ->
          assert GenerateAccessToken.generate("https://api.example.com/orders") == nil
        end)

      assert log =~ "[EndPointBlank] GenerateAccessToken failed: status=401"
    end
  end
end
