defmodule EndPointBlank.AccessTokensTest do
  @moduledoc """
  The token cache is what keeps the SDK from minting a credential per request,
  and its refresh buffer is what keeps it from handing out a token that expires
  in flight. Both are asserted through real TTLs rather than sleeps: the buffer
  is compared against wall-clock now, so a 60-second token is deterministically
  "near expiry" without waiting for anything.

  Intake issues a token against the application environment the authenticating
  credential belongs to, not against the hostname the request names. A node
  authenticates as one application environment, so it holds one token and the
  hostname is only ever part of the generation payload.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, Config}

  setup do
    # Tokens are minted inside the AccessTokens GenServer, not the test process.
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

    # One token is now shared by the whole node, so a leftover from another test
    # would be served here rather than sitting under its own hostname key.
    AccessTokens.clear()

    on_exit(fn ->
      Config.reset()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    unique = System.unique_integer([:positive])
    %{hostname: "host-#{unique}.test"}
  end

  # Mints a differently-named token on each call so a cached token and a freshly
  # minted one can be told apart.
  defp stub_minting(opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, 3600)
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:minted, Jason.decode!(raw)})

      expires_at = DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => "token-#{n}", "expired_at" => expires_at})
    end)
  end

  defp mint_count do
    receive do
      {:minted, _body} -> 1 + mint_count()
    after
      0 -> 0
    end
  end

  describe "minting and caching" do
    test "mints a token on first use", %{hostname: hostname} do
      stub_minting()

      assert AccessTokens.token(hostname) == "token-1"
    end

    test "serves the cached token to later callers instead of minting again", %{
      hostname: hostname
    } do
      stub_minting()

      assert AccessTokens.token(hostname) == "token-1"
      assert AccessTokens.token(hostname) == "token-1"
      assert mint_count() == 1
    end

    test "serves every hostname from the one token", %{hostname: hostname} do
      # The hostname arrives on the Host header, so the caller chooses it.
      # Minting per hostname meant a novel value cost a token exchange and a
      # database lookup on intake, for a token never scoped to the hostname.
      stub_minting()

      assert AccessTokens.token(hostname) == "token-1"
      assert AccessTokens.token("other-" <> hostname) == "token-1"
      assert AccessTokens.token("never-seen-" <> hostname) == "token-1"
      assert mint_count() == 1
    end

    test "asks for a token for the hostname it was called with", %{hostname: hostname} do
      stub_minting()
      Config.update(token_ttl: 900)

      AccessTokens.token(hostname)

      assert_receive {:minted, body}
      assert body["hostname"] == hostname
      assert body["token_ttl"] == 900
    end
  end

  describe "proactive refresh" do
    test "replaces a token that is close enough to expiry to die mid-request", %{
      hostname: hostname
    } do
      # 60 s is inside the two-minute refresh buffer. Serving it would hand a
      # caller a credential that can expire while the request is still open.
      stub_minting(ttl_seconds: 60)

      assert AccessTokens.token(hostname) == "token-1"
      assert AccessTokens.token(hostname) == "token-2"
    end

    test "keeps a token that is comfortably clear of expiry", %{hostname: hostname} do
      stub_minting(ttl_seconds: 3600)

      assert AccessTokens.token(hostname) == "token-1"
      assert AccessTokens.token(hostname) == "token-1"
    end
  end

  describe "exists?/0" do
    test "is false before any token is minted" do
      refute AccessTokens.exists?()
    end

    test "is true once a long-lived token is held", %{hostname: hostname} do
      stub_minting()
      AccessTokens.token(hostname)

      assert AccessTokens.exists?()
    end

    test "is false for a token too short-lived to be worth sending", %{hostname: hostname} do
      # Below the 30 s floor. Reporting it as usable would make the caller send a
      # Bearer that intake is about to reject, costing a pointless round trip.
      stub_minting(ttl_seconds: 10)
      AccessTokens.token(hostname)

      refute AccessTokens.exists?()
    end
  end

  describe "invalidate/1" do
    test "drops the token so the next caller mints a fresh one", %{hostname: hostname} do
      stub_minting()
      current = AccessTokens.token(hostname)

      AccessTokens.invalidate(current)

      assert AccessTokens.token(hostname) == "token-2"
    end

    test "ignores a token that has already been replaced", %{hostname: hostname} do
      # What stops a 401 from stampeding. Every request in flight when a token
      # is rejected reports the same stale value; only the first should cause a
      # mint, because the rest are holding a token that has already been
      # replaced and clearing for them would discard a good one.
      stub_minting()
      stale = AccessTokens.token(hostname)
      AccessTokens.invalidate(stale)
      AccessTokens.token(hostname)

      AccessTokens.invalidate(stale)

      assert AccessTokens.token(hostname) == "token-2"
      assert mint_count() == 2
    end

    test "ignores nil", %{hostname: hostname} do
      stub_minting()
      AccessTokens.token(hostname)

      AccessTokens.invalidate(nil)

      assert AccessTokens.token(hostname) == "token-1"
      assert mint_count() == 1
    end

    test "clear/0 drops the token", %{hostname: hostname} do
      stub_minting()
      AccessTokens.token(hostname)

      AccessTokens.clear()

      refute AccessTokens.exists?()
    end
  end

  describe "when a token cannot be obtained" do
    test "returns nil rather than raising into the caller's request", %{hostname: hostname} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      capture_log(fn -> assert AccessTokens.token(hostname) == nil end)
    end

    test "returns nil when the response carries an unreadable expiry", %{hostname: hostname} do
      # A token with an expiry we cannot read is worse than no token: it would be
      # cached with no way to know when to refresh it.
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"token" => "t", "expired_at" => "not-a-date"})
      end)

      assert AccessTokens.token(hostname) == nil
      refute AccessTokens.exists?()
    end

    test "returns nil when the response has no token at all", %{hostname: hostname} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"unexpected" => true})
      end)

      assert AccessTokens.token(hostname) == nil
    end

    test "does not cache the failure, so a later call can still succeed", %{hostname: hostname} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      capture_log(fn -> assert AccessTokens.token(hostname) == nil end)

      stub_minting()
      assert AccessTokens.token(hostname) == "token-1"
    end

    test "a held token is served without minting, so a refused hostname cannot disturb it", %{
      hostname: hostname
    } do
      stub_minting()
      assert AccessTokens.token(hostname) == "token-1"

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "unknown application"})
      end)

      assert AccessTokens.token("bogus-" <> hostname) == "token-1"
      assert AccessTokens.exists?()
    end

    test "discards the token it could not replace when a mint fails", %{hostname: hostname} do
      # Only a token already inside the refresh buffer reaches a mint, so the one
      # left behind is always close to death. Keeping it means exists?/0 — whose
      # floor is 30 seconds — goes on calling it usable, and a caller acting on
      # that presents a credential the intake is about to reject.
      stub_minting(ttl_seconds: 60)
      assert AccessTokens.token(hostname) == "token-1"

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "revoked"})
      end)

      capture_log(fn -> assert AccessTokens.token(hostname) == nil end)

      refute AccessTokens.exists?()
    end
  end
end
