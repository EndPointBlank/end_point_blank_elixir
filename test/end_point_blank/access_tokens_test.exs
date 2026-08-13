defmodule EndPointBlank.AccessTokensTest do
  @moduledoc """
  The token cache is what keeps the SDK from minting a credential per request,
  and its refresh buffer is what keeps it from handing out a token that expires
  in flight. Both are asserted through real TTLs rather than sleeps: the buffer
  is compared against wall-clock now, so a 60-second token is deterministically
  "near expiry" without waiting for anything.

  A token is cached under the canonical base URL intake resolved the request
  to -- not under the URL the caller supplied. A caller asks for the URL it is
  about to call; intake answers with the base URL of the environment that URL
  belongs to, and subsequent calls anywhere under that base URL reuse the
  entry. A node that calls several targets therefore holds several tokens,
  which is the whole reason the cache is a map.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, Config}

  setup do
    # Tokens are minted inside the AccessTokens GenServer, not the test process.
    Req.Test.set_req_test_to_shared()
    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})
    Config.update(client_id: "cid", client_secret: "csecret", base_url: "https://intake.test")

    # Each test gets its own base_url, so a leftover entry from another test
    # would miss the matcher here rather than being served by accident.
    AccessTokens.clear()

    on_exit(fn ->
      Config.reset()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    unique = System.unique_integer([:positive])
    %{base_url: "https://host-#{unique}.test"}
  end

  # Mints a differently-named token on each call, echoing the request's
  # base_url back as the resolved one unless `:base_url` is given -- which
  # matches the common case where the request URL IS the registered base URL.
  defp stub_minting(opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, 3600)
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request_body = Jason.decode!(raw)
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(test_pid, {:minted, request_body})

      expires_at = DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
      resolved = Keyword.get(opts, :base_url, request_body["base_url"])

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => "token-#{n}", "expired_at" => expires_at, "base_url" => resolved})
    end)
  end

  # Answers a fixed sequence of payloads, one per call, in order -- for the
  # cases where the resolved base_url has to differ from the requested URL.
  defp stub_sequence(payloads) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> payloads end)

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:minted, Jason.decode!(raw)})

      [next | rest] = Agent.get(agent, & &1)
      Agent.update(agent, fn _ -> rest end)

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(next)
    end)
  end

  defp token_payload(token, opts) do
    ttl = Keyword.get(opts, :ttl_seconds, 3600)
    expires_at = DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
    body = %{"token" => token, "expired_at" => expires_at}

    case Keyword.get(opts, :base_url) do
      nil -> body
      base_url -> Map.put(body, "base_url", base_url)
    end
  end

  defp mint_count do
    receive do
      {:minted, _body} -> 1 + mint_count()
    after
      0 -> 0
    end
  end

  describe "keying on the base URL" do
    test "caches under the base_url intake resolved to, reusing it for any path beneath it",
         %{base_url: base} do
      stub_minting(base_url: base <> "/orders")

      assert AccessTokens.token(base <> "/orders/widgets/42") == "token-1"
      # A different path under the same registered base_url reuses the entry.
      assert AccessTokens.token(base <> "/orders/anything") == "token-1"

      assert_receive {:minted, body}
      # The caller's URL went out verbatim; the response's base_url became the key.
      assert body["base_url"] == base <> "/orders/widgets/42"
      assert mint_count() == 0
    end

    test "distinct base urls are kept apart", %{base_url: base} do
      # The reason the cache is a map at all: a service that calls two targets
      # needs a token for each, and holding one would send the wrong
      # credential to the second.
      other = "https://other-" <> String.trim_leading(base, "https://")
      stub_minting()

      assert AccessTokens.token(base) == "token-1"
      assert AccessTokens.token(other) == "token-2"
      assert AccessTokens.token(base) == "token-1"

      assert mint_count() == 2
    end

    test "the longest matching prefix wins", %{base_url: base} do
      # Seeded narrow-first: once the broad entry exists nothing under it can
      # miss, so this is the only order in which both entries can be created.
      stub_sequence([
        token_payload("narrow", base_url: base <> "/orders"),
        token_payload("broad", base_url: base)
      ])

      AccessTokens.token(base <> "/orders/42")
      AccessTokens.token(base <> "/other")

      assert AccessTokens.token(base <> "/orders/42") == "narrow"
      assert AccessTokens.token(base <> "/other") == "broad"
      assert mint_count() == 2
    end

    test "a prefix match respects segment boundaries", %{base_url: base} do
      # "/ordersXX" must NOT match "/orders" -- a prefix that stops mid-segment
      # is a different resource, and reusing the token would present it to a
      # base URL it was never issued for.
      stub_minting()

      AccessTokens.token(base <> "/orders")

      assert AccessTokens.token(base <> "/ordersXX") == "token-2"
      assert mint_count() == 2
    end

    test "a differently-cased URL misses rather than guessing", %{base_url: base} do
      # The SDK does not normalize -- intake owns that rule. A URL that does
      # not match character-for-character costs one extra request, which is
      # cheaper than presenting a token issued for somewhere else.
      stub_minting()

      AccessTokens.token(base <> "/orders")

      assert AccessTokens.token(base <> "/Orders") == "token-2"
      assert mint_count() == 2
    end

    test "a URL carrying a query string misses rather than guessing", %{base_url: base} do
      # It should have been stripped before it got here; missing is the right
      # answer when it was not.
      stub_minting()

      AccessTokens.token(base <> "/orders")

      assert AccessTokens.token(base <> "/orders?page=2") == "token-2"
      assert mint_count() == 2
    end

    test "a trailing slash still matches", %{base_url: base} do
      # Falls out of the "key <> /" rule rather than from any normalization:
      # ".../orders/" starts with ".../orders" <> "/". Worth pinning, because
      # it is the one non-identical form that does NOT cost an extra mint.
      stub_minting()

      AccessTokens.token(base <> "/orders")

      assert AccessTokens.token(base <> "/orders/") == "token-1"
      assert mint_count() == 1
    end
  end

  describe "minting and caching" do
    test "mints a token on first use", %{base_url: base} do
      stub_minting()

      assert AccessTokens.token(base) == "token-1"
    end

    test "serves the cached token to later callers instead of minting again", %{base_url: base} do
      stub_minting()

      assert AccessTokens.token(base) == "token-1"
      assert AccessTokens.token(base) == "token-1"
      assert mint_count() == 1
    end

    test "asks for a token for the base_url it was called with, verbatim", %{base_url: base} do
      stub_minting()
      Config.update(token_ttl: 900)
      messy = base <> "/Orders?ignored=1"

      AccessTokens.token(messy)

      assert_receive {:minted, body}
      # No downcasing, trimming, or reduction to a hostname -- intake owns
      # normalization, and altering the argument would change which
      # environment the caller is asking for.
      assert body["base_url"] == messy
      assert body["token_ttl"] == 900
    end
  end

  describe "proactive refresh" do
    test "replaces a token that is close enough to expiry to die mid-request", %{base_url: base} do
      # 60 s is inside the two-minute refresh buffer. Serving it would hand a
      # caller a credential that can expire while the request is still open.
      stub_minting(ttl_seconds: 60)

      assert AccessTokens.token(base) == "token-1"
      assert AccessTokens.token(base) == "token-2"
    end

    test "keeps a token that is comfortably clear of expiry", %{base_url: base} do
      stub_minting(ttl_seconds: 3600)

      assert AccessTokens.token(base) == "token-1"
      assert AccessTokens.token(base) == "token-1"
    end
  end

  describe "exists?/1" do
    test "is false before any token is minted", %{base_url: base} do
      refute AccessTokens.exists?(base)
    end

    test "is true once a long-lived token is held", %{base_url: base} do
      stub_minting()
      AccessTokens.token(base)

      assert AccessTokens.exists?(base)
    end

    test "is true for a sub-path of a cached base_url", %{base_url: base} do
      # exists?/1 goes through the same prefix matcher token/1 does, so a
      # deeper path under a cached base_url reads as covered. Answering false
      # here would report a token as absent that the very next token/1 call
      # serves from cache.
      stub_minting()
      AccessTokens.token(base)

      assert AccessTokens.exists?(base <> "/widgets/42")
    end

    test "is false for a base_url no held token covers", %{base_url: base} do
      stub_minting()
      AccessTokens.token(base)

      refute AccessTokens.exists?("https://elsewhere.test")
    end

    test "is false for a token too short-lived to be worth sending", %{base_url: base} do
      # Below the 30 s floor. Reporting it as usable would make the caller send a
      # Bearer that intake is about to reject, costing a pointless round trip.
      stub_minting(ttl_seconds: 10)
      AccessTokens.token(base)

      refute AccessTokens.exists?(base)
    end
  end

  describe "invalidate/1" do
    test "drops the token so the next caller mints a fresh one", %{base_url: base} do
      stub_minting()
      current = AccessTokens.token(base)

      AccessTokens.invalidate(current)

      assert AccessTokens.token(base) == "token-2"
    end

    test "finds the entry by token value and drops only that one", %{base_url: base} do
      # A rejected caller holds a token, not a URL, so the lookup cannot be by
      # base_url -- and the tokens held for other targets are still good.
      other = "https://other-" <> String.trim_leading(base, "https://")
      stub_minting()

      a = AccessTokens.token(base)
      AccessTokens.token(other)

      AccessTokens.invalidate(a)

      refute AccessTokens.exists?(base)
      assert AccessTokens.exists?(other)
    end

    test "ignores a token that has already been replaced", %{base_url: base} do
      # What stops a 401 from stampeding. Every request in flight when a token
      # is rejected reports the same stale value; only the first should cause a
      # mint, because the rest are holding a token that has already been
      # replaced and clearing for them would discard a good one.
      stub_minting()
      stale = AccessTokens.token(base)
      AccessTokens.invalidate(stale)
      AccessTokens.token(base)

      AccessTokens.invalidate(stale)

      assert AccessTokens.token(base) == "token-2"
      assert mint_count() == 2
    end

    test "ignores nil", %{base_url: base} do
      stub_minting()
      AccessTokens.token(base)

      AccessTokens.invalidate(nil)

      assert AccessTokens.token(base) == "token-1"
      assert mint_count() == 1
    end
  end

  describe "clear/0" do
    test "drops every cached token", %{base_url: base} do
      other = "https://other-" <> String.trim_leading(base, "https://")
      stub_minting()

      AccessTokens.token(base)
      AccessTokens.token(other)

      AccessTokens.clear()

      refute AccessTokens.exists?(base)
      refute AccessTokens.exists?(other)
    end
  end

  describe "when a token cannot be obtained" do
    test "returns nil rather than raising into the caller's request", %{base_url: base} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      capture_log(fn -> assert AccessTokens.token(base) == nil end)
    end

    test "keeps a token for an hour when the response carries an unreadable expiry", %{
      base_url: base
    } do
      # An hour is a guess, but a working one, and it is what the other four SDKs
      # do. Treating the token as unusable instead means a mint on every inbound
      # request for as long as the intake misbehaves.
      test_pid = self()

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        send(test_pid, {:minted, %{}})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"token" => "t", "expired_at" => "not-a-date", "base_url" => base})
      end)

      assert AccessTokens.token(base) == "t"
      assert AccessTokens.token(base) == "t"
      assert AccessTokens.exists?(base)
      # The second call came from the held token, not a second mint.
      assert mint_count() == 1
    end

    test "does the same when the expiry is missing entirely", %{base_url: base} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "t", "base_url" => base})
      end)

      assert AccessTokens.token(base) == "t"
      assert AccessTokens.exists?(base)
    end

    test "returns nil when the response has no token at all", %{base_url: base} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"unexpected" => true})
      end)

      assert AccessTokens.token(base) == nil
    end

    test "treats a response with a token but no base_url as a failed mint", %{base_url: base} do
      # Without a base_url there is no application environment to cache the
      # token under, so no token is handed back either. Keying on the
      # caller's URL instead would store an entry per resource URL, and
      # nothing here evicts it -- a bounded extra request traded for an
      # unbounded leak.
      test_pid = self()

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        send(test_pid, {:minted, %{}})
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"token" => "tok-1"})
      end)

      log =
        capture_log(fn ->
          assert AccessTokens.token(base <> "/1") == nil
          assert AccessTokens.token(base <> "/2") == nil
        end)

      refute AccessTokens.exists?(base <> "/1")
      # Nothing was cached, so the second call had to ask again.
      assert mint_count() == 2
      # Says what actually happened: a broken server, not a bad request.
      assert log =~ "carried a token but no base_url"
    end

    test "does not cache the failure, so a later call can still succeed", %{base_url: base} do
      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      capture_log(fn -> assert AccessTokens.token(base) == nil end)

      stub_minting()
      assert AccessTokens.token(base) == "token-1"
    end

    test "a live token is served without minting, so a refused deeper path cannot disturb it", %{
      base_url: base
    } do
      stub_minting()
      assert AccessTokens.token(base) == "token-1"

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "unknown application"})
      end)

      assert AccessTokens.token(base <> "/42") == "token-1"
      assert AccessTokens.exists?(base)
    end

    test "discards the token it could not replace when a mint fails", %{base_url: base} do
      # Only a token already inside the refresh buffer reaches a mint, so the one
      # left behind is always close to death. Keeping it means exists?/1 -- whose
      # floor is 30 seconds -- goes on calling it usable, and a caller acting on
      # that presents a credential intake is about to reject.
      stub_minting(ttl_seconds: 60)
      assert AccessTokens.token(base) == "token-1"

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "revoked"})
      end)

      capture_log(fn -> assert AccessTokens.token(base) == nil end)

      refute AccessTokens.exists?(base)
    end

    test "a failure leaves other base urls untouched", %{base_url: base} do
      # Only the entry covering the failed base_url is dropped. Intake refusing
      # one target must not cost the tokens held for every other target.
      other = "https://other-" <> String.trim_leading(base, "https://")

      stub_minting(ttl_seconds: 60)
      assert AccessTokens.token(base) == "token-1"
      assert AccessTokens.token(other) == "token-2"

      Req.Test.stub(__MODULE__.Stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "revoked"})
      end)

      capture_log(fn -> assert AccessTokens.token(base) == nil end)

      refute AccessTokens.exists?(base)
      assert AccessTokens.exists?(other)
    end
  end

  describe "a nil or empty base_url" do
    test "does not crash the GenServer when the cache is warm", %{base_url: base} do
      # The crash this pins only happens with a warm cache -- the matcher's
      # comparison never touches its argument when there is nothing to
      # iterate. This is the consequence that matters: `AccessTokens` is a
      # GenServer supervised `:one_for_one` with no `max_restarts` override,
      # so it inherits OTP's default of 3 restarts in 5 seconds. A
      # `FunctionClauseError` here does not just fail this call -- enough of
      # them in a row take the whole supervisor, and the host application,
      # down with it.
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      capture_log(fn -> assert AccessTokens.token(nil) == nil end)

      # Comparing pids, not just `Process.alive?/1`: a crashed GenServer is
      # restarted by its supervisor almost instantly, so a live process would
      # still answer under this name even after a crash -- `Process.alive?/1`
      # alone cannot tell "never died" from "died and came back." Identical
      # pids mean the process that answered before is the one answering after.
      assert Process.whereis(AccessTokens) == pid
      assert Process.alive?(pid)

      # A restart would also have thrown away the cache. Confirm the entry
      # seeded above is still being served rather than re-minted.
      assert AccessTokens.token(base) == "token-1"
      assert mint_count() == 2
    end

    test "reaches the same outcome whether the cache is cold or warm", %{base_url: base} do
      # Cold cache: the match loop body never runs, so nothing raises today --
      # the call proceeds to mint with a nil base_url and takes the "carried a
      # token but no base_url" failure as an ordinary miss.
      stub_minting()

      cold_log = capture_log(fn -> assert AccessTokens.token(nil) == nil end)
      assert cold_log =~ "carried a token but no base_url"

      # Warm the cache with a real entry, then repeat with nil. The fix makes
      # this take the exact same ordinary-miss path as the cold call above,
      # rather than crashing the GenServer.
      assert AccessTokens.token(base) == "token-2"

      warm_log = capture_log(fn -> assert AccessTokens.token(nil) == nil end)
      assert warm_log =~ "carried a token but no base_url"

      # The real entry is undisturbed by either nil call.
      assert AccessTokens.token(base) == "token-2"
    end

    test "an empty string base_url does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      capture_log(fn -> assert AccessTokens.token("") == nil end)

      assert Process.whereis(AccessTokens) == pid
      assert AccessTokens.token(base) == "token-1"
    end

    test "an integer base_url does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      # Not just nil and "" -- any non-binary reaches the identical
      # `String.starts_with?/2` call and raises the identical
      # `FunctionClauseError`. `token/1` is public API; a host application
      # can pass anything.
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      capture_log(fn -> assert AccessTokens.token(123) == nil end)

      assert Process.whereis(AccessTokens) == pid
      assert Process.alive?(pid)
      assert AccessTokens.token(base) == "token-1"
    end

    test "an atom base_url does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      # Not asserting the return value here: an atom argument survives the
      # matcher (this test's point) but still goes out over the wire, where
      # JSON encoding turns it into a string before it comes back around --
      # what matters is that the process answering afterward is still the
      # one that was answering before.
      capture_log(fn -> AccessTokens.token(:not_a_url) end)

      assert Process.whereis(AccessTokens) == pid
      assert Process.alive?(pid)
      assert AccessTokens.token(base) == "token-1"
    end

    test "a map base_url does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      # The matcher already lets this through as a miss (it isn't a binary).
      # The crash this pins is a step further along: the ordinary-miss
      # failure branch logs `"...for #{base_url}..."`, and `String.Chars` has
      # no implementation for Map, so that interpolation itself raises
      # `Protocol.UndefinedError` and kills the GenServer -- same consequence
      # as the FunctionClauseError, one step later in the same call.
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      capture_log(fn -> AccessTokens.token(%{}) end)

      assert Process.whereis(AccessTokens) == pid
      assert Process.alive?(pid)
      assert AccessTokens.token(base) == "token-1"
    end

    test "a tuple base_url does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      # A tuple can't even be minted -- Jason has no encoder for it, so
      # `safe_generate/1`'s own rescue catches that and returns nil -- but
      # the failure branch's `"...for #{base_url}..."` log line is reached
      # regardless, outside that rescue boundary, and raises the same way a
      # map does.
      stub_minting()
      assert AccessTokens.token(base) == "token-1"
      pid = Process.whereis(AccessTokens)

      capture_log(fn -> AccessTokens.token({1, 2}) end)

      assert Process.whereis(AccessTokens) == pid
      assert Process.alive?(pid)
      assert AccessTokens.token(base) == "token-1"
    end

    test "exists?/1 with nil does not crash the GenServer when the cache is warm",
         %{base_url: base} do
      # exists?/1 reaches the same matcher through a different handle_call
      # clause, so the fix has to hold there too, not just for token/1.
      stub_minting()
      AccessTokens.token(base)
      pid = Process.whereis(AccessTokens)

      refute AccessTokens.exists?(nil)

      assert Process.whereis(AccessTokens) == pid
    end
  end

  describe "a refresh that resolves to a different base_url" do
    test "drops the stale key the matched entry was stored under", %{base_url: base} do
      narrow = base <> "/orders"

      # Seed a near-expiry entry under the longer, more specific URL -- the
      # one that keeps winning the longest-match race as long as it survives.
      stub_sequence([token_payload("narrow-token", base_url: narrow, ttl_seconds: 60)])
      assert AccessTokens.token(narrow) == "narrow-token"

      # The environment's registered base_url changes to a shorter path, so a
      # refresh for the same caller URL now resolves to a different canonical
      # base_url than the one that is cached.
      stub_sequence([token_payload("broad-token", base_url: base, ttl_seconds: 3600)])
      assert AccessTokens.token(narrow) == "broad-token"

      state = :sys.get_state(AccessTokens)
      refute Map.has_key?(state, narrow)
      assert Map.has_key?(state, base)

      # The sharpest check: a follow-up call for the same URL must be served
      # from the fresh `base` entry, not mint again because the stale, still
      # near-expiry `narrow` entry outranks it in the longest-match race.
      # `mint_count/0` is cumulative for the whole test, and the two calls
      # above already legitimately minted once each -- so no *new* mint on
      # this third call is what keeps the total at 2, not 3.
      stub_minting()
      assert AccessTokens.token(narrow) == "broad-token"
      assert mint_count() == 2
    end
  end
end
