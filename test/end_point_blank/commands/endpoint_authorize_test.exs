defmodule EndPointBlank.Commands.EndpointAuthorizeTest do
  @moduledoc """
  The authorize command decides whether a request is allowed to proceed, so a
  regression here is either an outage (legitimate traffic refused) or a hole
  (traffic allowed that should not be). It also owns the cache that most
  requests are answered from, and the credential downgrade that keeps the
  service usable when a token expires mid-flight.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.{AccessTokens, AuthCache, Config, RequestStore}
  alias EndPointBlank.Commands.EndpointAuthorize

  @authorize_path "/api/authorize"
  @token_path "/api/access_token"

  setup do
    # Token minting happens inside the AccessTokens GenServer, not the test
    # process, so the stub has to be visible process-wide.
    Req.Test.set_req_test_to_shared()

    Application.put_env(:end_point_blank_elixir, :req_test_plug, {Req.Test, __MODULE__.Stub})

    Config.update(
      app_name: "test-app",
      client_id: "cid",
      client_secret: "csecret",
      base_url: "https://intake.test"
    )

    on_exit(fn ->
      Config.reset()
      RequestStore.clear()
      AccessTokens.clear()
      Application.delete_env(:end_point_blank_elixir, :req_test_plug)
      Req.Test.set_req_test_to_private()
    end)

    # The auth cache is process-wide and has no public clear, so every test
    # works on a path and hostname nothing else will collide with.
    unique = System.unique_integer([:positive])
    %{path: "/books/#{unique}", hostname: "host-#{unique}.test"}
  end

  # ── Stubbing ────────────────────────────────────────────────────────────────

  # Installs the intake stub. `handlers` maps a request path to a responder
  # taking `(conn, call)`, where `call` is the already-decoded request; every
  # call is also recorded for later inspection.
  defp stub_intake(handlers) do
    test_pid = self()

    # Authorization mints a token before every authorize call, so the token path
    # has to answer by default — otherwise every test here would quietly
    # exercise the Basic fallback instead of the Bearer path production uses. A
    # test that cares overrides it, and an unexpected path still raises.
    handlers = Map.merge(%{@token_path => minting_token("test-token")}, handlers)

    Req.Test.stub(__MODULE__.Stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      call = %{
        path: conn.request_path,
        body: Jason.decode!(raw),
        auth: conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      }

      send(test_pid, {:intake_call, call})
      Map.fetch!(handlers, conn.request_path).(conn, call)
    end)
  end

  defp authorized(opts \\ []) do
    env_id = Keyword.get(opts, :source_env_id, "app-env-1")
    deprecation = Keyword.get(opts, :deprecation)

    body =
      %{"accesses" => [%{"source_application_environment_id" => env_id}]}
      |> then(fn b -> if deprecation, do: Map.put(b, "deprecation", deprecation), else: b end)

    responding(201, body)
  end

  defp responding(status, body) do
    fn conn, _call -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end
  end

  defp unreachable do
    fn conn, _call -> Req.Test.transport_error(conn, :econnrefused) end
  end

  defp minting_token(token, opts \\ []) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :ttl_seconds, 3600), :second)
      |> DateTime.to_iso8601()

    responding(201, %{"token" => token, "expired_at" => expires_at})
  end

  # Refuses the stale Bearer once and grants whatever credential is retried.
  defp rejecting_stale_bearer do
    fn conn, call ->
      if call.auth == "Bearer stale-token" do
        responding(401, %{"error" => "expired"}).(conn, call)
      else
        authorized().(conn, call)
      end
    end
  end

  # Every intake call made so far, oldest first. The command's HTTP calls are
  # all synchronous, so by the time authorize/3 returns the mailbox is complete.
  defp intake_calls do
    receive do
      {:intake_call, call} -> [call | intake_calls()]
    after
      0 -> []
    end
  end

  defp authorize_calls, do: Enum.filter(intake_calls(), &(&1.path == @authorize_path))

  # ── Conn building ───────────────────────────────────────────────────────────

  defp conn(ctx, opts \\ []) do
    method = Keyword.get(opts, :method, "GET")
    path = Keyword.get(opts, :path, ctx.path)

    Plug.Test.conn(method, path)
    |> Map.put(:host, Keyword.get(opts, :hostname, ctx.hostname))
    |> then(fn c ->
      case Keyword.get(opts, :client_auth) do
        nil -> c
        value -> Plug.Conn.put_req_header(c, "authorization", value)
      end
    end)
  end

  # AuthCache.put/2 is a cast; syncing on the GenServer guarantees the entry has
  # landed before the next lookup, so cache assertions are not a race.
  defp sync_cache, do: :sys.get_state(AuthCache)

  # ── Tests ───────────────────────────────────────────────────────────────────

  describe "a successful authorization" do
    test "lets the request proceed and records the source environment id", ctx do
      stub_intake(%{@authorize_path => authorized(source_env_id: "app-env-42")})

      assert {:ok, %Plug.Conn{}} = EndpointAuthorize.authorize(conn(ctx))
      assert RequestStore.get_source_env_id() == "app-env-42"
    end

    test "authenticates to intake with a token it minted, not the client credentials", ctx do
      # The short-lived token is the whole point of the token endpoint. Nothing
      # mints the first one except this call path, so if the header asked
      # whether a token already existed instead of asking for one, every request
      # for the life of the node would carry the long-lived client secret.
      stub_intake(%{@authorize_path => authorized()})

      EndpointAuthorize.authorize(conn(ctx))

      assert [call] = authorize_calls()
      assert call.auth == "Bearer test-token"
    end

    test "describes the request to intake so it can be matched to an endpoint", ctx do
      stub_intake(%{@authorize_path => authorized()})
      RequestStore.put_uuid("uuid-abc")

      EndpointAuthorize.authorize(conn(ctx, method: "POST"), ctx.path, "v3")

      assert [call] = authorize_calls()
      assert call.body["path"] == ctx.path
      assert call.body["http_method"] == "POST"
      assert call.body["application"] == "test-app"
      assert call.body["endpoint_version"] == "v3"
      assert call.body["target_hostname"] == ctx.hostname
      # Without the uuid the auth decision cannot be joined to the request it
      # belongs to in the portal's request trail.
      assert call.body["uuid"] == "uuid-abc"
    end

    test "forwards the caller's own Authorization header as client_auth", ctx do
      stub_intake(%{@authorize_path => authorized()})

      EndpointAuthorize.authorize(conn(ctx, client_auth: "Bearer caller-token"))

      assert [call] = authorize_calls()
      assert call.body["client_auth"] == "Bearer caller-token"
    end

    test "sends the caller's IP address in dotted form", ctx do
      stub_intake(%{@authorize_path => authorized()})

      EndpointAuthorize.authorize(%{conn(ctx) | remote_ip: {203, 0, 113, 7}})

      assert [call] = authorize_calls()
      assert call.body["source_ip"] == "203.0.113.7"
    end

    test "omits the IP rather than failing when the adapter did not supply one", ctx do
      stub_intake(%{@authorize_path => authorized()})

      assert {:ok, _} = EndpointAuthorize.authorize(%{conn(ctx) | remote_ip: nil})

      assert [call] = authorize_calls()
      assert call.body["source_ip"] == nil
    end

    test "defaults the path and version from the conn when not given explicitly", ctx do
      stub_intake(%{@authorize_path => authorized()})

      request = Plug.Conn.put_req_header(conn(ctx), "x-api-version", "7")
      EndpointAuthorize.authorize(request)

      assert [call] = authorize_calls()
      assert call.body["path"] == ctx.path
      assert call.body["endpoint_version"] == "7"
    end

    test "accepts a response that grants access without naming an environment", ctx do
      stub_intake(%{@authorize_path => responding(201, %{"accesses" => []})})

      assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx))
      assert RequestStore.get_source_env_id() == nil
    end
  end

  describe "deprecation reported with the authorization" do
    test "sets Deprecation and Sunset on the response", ctx do
      deprecation = %{
        "deprecated_at" => "2026-01-01T00:00:00Z",
        "sunset_at" => "2026-11-11T11:11:11Z"
      }

      stub_intake(%{@authorize_path => authorized(deprecation: deprecation)})

      assert {:ok, out} = EndpointAuthorize.authorize(conn(ctx))
      assert Plug.Conn.get_resp_header(out, "deprecation") == ["@1767225600"]
      assert Plug.Conn.get_resp_header(out, "sunset") == ["Wed, 11 Nov 2026 11:11:11 GMT"]
    end

    test "sets no headers when intake reports no deprecation", ctx do
      stub_intake(%{@authorize_path => authorized()})

      assert {:ok, out} = EndpointAuthorize.authorize(conn(ctx))
      assert Plug.Conn.get_resp_header(out, "deprecation") == []
      assert Plug.Conn.get_resp_header(out, "sunset") == []
    end

    test "ignores a deprecation block that is not a map", ctx do
      stub_intake(%{@authorize_path => responding(201, %{"deprecation" => "soon"})})

      assert {:ok, out} = EndpointAuthorize.authorize(conn(ctx))
      assert Plug.Conn.get_resp_header(out, "deprecation") == []
    end
  end

  describe "caching" do
    test "a repeated request is answered without calling intake again", ctx do
      stub_intake(%{@authorize_path => authorized()})

      EndpointAuthorize.authorize(conn(ctx))
      sync_cache()
      assert length(authorize_calls()) == 1

      assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx))
      assert authorize_calls() == []
    end

    test "a cache hit still records the source environment id", ctx do
      stub_intake(%{@authorize_path => authorized(source_env_id: "app-env-cached")})

      EndpointAuthorize.authorize(conn(ctx))
      sync_cache()
      RequestStore.clear()

      assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx))
      assert RequestStore.get_source_env_id() == "app-env-cached"
    end

    test "a cache hit still sets the deprecation headers", ctx do
      # Authorization is cached per client and route, so a deprecation carried
      # only on the miss would surface on roughly one request in N — which reads
      # as a flaky header rather than a deprecated endpoint.
      deprecation = %{"deprecated_at" => "2026-01-01T00:00:00Z"}
      stub_intake(%{@authorize_path => authorized(deprecation: deprecation)})

      EndpointAuthorize.authorize(conn(ctx))
      sync_cache()
      _primed = authorize_calls()

      assert {:ok, out} = EndpointAuthorize.authorize(conn(ctx))
      assert authorize_calls() == []
      assert Plug.Conn.get_resp_header(out, "deprecation") == ["@1767225600"]
    end

    test "an entry cached in the pre-deprecation shape still authorizes", ctx do
      # Entries written by an earlier build of this module hold a bare id rather
      # than a {id, deprecation} tuple; after a hot upgrade they are still in the
      # table, and must not be read as a malformed hit.
      stub_intake(%{@authorize_path => authorized()})

      key = "epb_auth::#{ctx.path}:GET:test-app:"
      AuthCache.put(key, "app-env-legacy")
      sync_cache()

      assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx))
      assert authorize_calls() == []
      assert RequestStore.get_source_env_id() == "app-env-legacy"
    end

    test "a failed authorization is not cached", ctx do
      stub_intake(%{@authorize_path => responding(403, %{"error" => "forbidden"})})

      capture_log(fn ->
        assert {:error, 403, _} = EndpointAuthorize.authorize(conn(ctx))
        sync_cache()
        assert {:error, 403, _} = EndpointAuthorize.authorize(conn(ctx))
      end)

      # A cached refusal would keep refusing after the grant was fixed in the
      # portal, for the whole TTL.
      assert length(authorize_calls()) == 2
    end
  end

  describe "what the cache key distinguishes" do
    setup ctx do
      stub_intake(%{@authorize_path => authorized()})
      EndpointAuthorize.authorize(conn(ctx, client_auth: "Bearer caller-one"))
      sync_cache()
      _primed = authorize_calls()
      :ok
    end

    test "a different caller does not inherit the first caller's authorization", ctx do
      EndpointAuthorize.authorize(conn(ctx, client_auth: "Bearer caller-two"))

      assert length(authorize_calls()) == 1
    end

    test "an unauthenticated caller does not inherit an authenticated one's", ctx do
      EndpointAuthorize.authorize(conn(ctx))

      assert length(authorize_calls()) == 1
    end

    test "a different path is authorized on its own", ctx do
      EndpointAuthorize.authorize(
        conn(ctx, path: ctx.path <> "/other", client_auth: "Bearer caller-one")
      )

      assert length(authorize_calls()) == 1
    end

    test "a different HTTP method on the same path is authorized on its own", ctx do
      EndpointAuthorize.authorize(conn(ctx, method: "DELETE", client_auth: "Bearer caller-one"))

      assert length(authorize_calls()) == 1
    end

    test "a different configured application is authorized on its own", ctx do
      Config.update(app_name: "other-app")

      EndpointAuthorize.authorize(conn(ctx, client_auth: "Bearer caller-one"))

      assert length(authorize_calls()) == 1
    end

    test "a different endpoint version is authorized on its own", ctx do
      # Access is granted per endpoint version, and the deprecation travels with
      # it. Sharing one entry across versions would let a caller on v2 ride a v1
      # grant and see v1's deprecation.
      EndpointAuthorize.authorize(conn(ctx, client_auth: "Bearer caller-one"), ctx.path, "v9")

      assert length(authorize_calls()) == 1
    end
  end

  describe "request-to-request isolation" do
    # Phoenix runs each request in its own process and each conn is a fresh
    # value, so there is no shared slot to bleed through. Asserted anyway,
    # because the deprecation now travels through a process-wide cache.
    test "a healthy version's response carries no headers from a deprecated one", ctx do
      stub_intake(%{
        @authorize_path => fn conn, call ->
          deprecation =
            if call.body["endpoint_version"] == "v1",
              do: %{"deprecated_at" => "2026-01-01T00:00:00Z"},
              else: nil

          authorized(deprecation: deprecation).(conn, call)
        end
      })

      {:ok, deprecated} = EndpointAuthorize.authorize(conn(ctx), ctx.path, "v1")
      {:ok, healthy} = EndpointAuthorize.authorize(conn(ctx), ctx.path, "v2")

      assert Plug.Conn.get_resp_header(deprecated, "deprecation") == ["@1767225600"]
      assert Plug.Conn.get_resp_header(healthy, "deprecation") == []
    end

    test "concurrent requests each get only their own headers", ctx do
      stub_intake(%{
        @authorize_path => fn conn, call ->
          version = call.body["endpoint_version"]

          authorized(deprecation: %{"deprecated_at" => "202#{version}-01-01T00:00:00Z"}).(
            conn,
            call
          )
        end
      })

      parent = self()

      for version <- ["3", "4", "5"] do
        spawn(fn ->
          {:ok, out} = EndpointAuthorize.authorize(conn(ctx), ctx.path, version)
          send(parent, {version, Plug.Conn.get_resp_header(out, "deprecation")})
        end)
      end

      expected =
        Map.new(["3", "4", "5"], fn version ->
          {:ok, dt, _} = DateTime.from_iso8601("202#{version}-01-01T00:00:00Z")
          {version, ["@#{DateTime.to_unix(dt)}"]}
        end)

      for version <- ["3", "4", "5"] do
        assert_receive {^version, header}, 2_000
        assert header == expected[version]
      end
    end
  end

  describe "an expired access token" do
    setup ctx do
      stub_intake(%{@token_path => minting_token("stale-token")})
      assert AccessTokens.token(ctx.hostname) == "stale-token"
      _minted = intake_calls()
      :ok
    end

    test "is discarded and the call retried with a freshly minted one", ctx do
      stub_intake(%{
        @token_path => minting_token("fresh-token"),
        @authorize_path => rejecting_stale_bearer()
      })

      assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx))

      assert [first, second] = authorize_calls()
      assert first.auth == "Bearer stale-token"
      assert second.auth == "Bearer fresh-token"
    end

    test "falls back to Basic credentials when no fresh token can be minted", ctx do
      stub_intake(%{
        @token_path => responding(500, %{"error" => "down"}),
        @authorize_path => rejecting_stale_bearer()
      })

      capture_log(fn -> assert {:ok, _} = EndpointAuthorize.authorize(conn(ctx)) end)

      assert [_first, second] = authorize_calls()
      assert second.auth == "Basic " <> Base.encode64("cid:csecret")
    end

    test "is removed from the cache so later requests do not resend it", ctx do
      stub_intake(%{
        @token_path => responding(500, %{"error" => "down"}),
        @authorize_path => rejecting_stale_bearer()
      })

      capture_log(fn -> EndpointAuthorize.authorize(conn(ctx)) end)

      refute AccessTokens.exists?()
    end

    test "is not retried when the rejected call already used Basic credentials", ctx do
      # Retrying Basic with Basic would double every request against an intake
      # that is simply refusing these credentials.
      AccessTokens.clear()

      # Minting has to fail for the call to go out on Basic at all, now that
      # the header mints rather than checking whether a token already exists.
      stub_intake(%{
        @token_path => responding(500, %{"error" => "down"}),
        @authorize_path => responding(401, %{"error" => "nope"})
      })

      capture_log(fn ->
        assert {:error, 401, _} = EndpointAuthorize.authorize(conn(ctx))
      end)

      assert [only] = authorize_calls()
      assert String.starts_with?(only.auth, "Basic ")
    end
  end

  describe "when intake refuses or is unavailable" do
    test "returns the status and body intake gave, so the caller can relay it", ctx do
      stub_intake(%{@authorize_path => responding(403, %{"error" => "no access"})})

      log =
        capture_log(fn ->
          assert {:error, 403, body} = EndpointAuthorize.authorize(conn(ctx))
          assert body == %{"error" => "no access"}
        end)

      assert log =~ "Authorization failed"
    end

    test "reports the service unavailable when the host cannot be reached", ctx do
      stub_intake(%{@authorize_path => unreachable()})

      log =
        capture_log(fn ->
          assert EndpointAuthorize.authorize(conn(ctx)) == {:error, :service_unavailable}
        end)

      assert log =~ "Authorization error"
    end

    test "does not record a source environment id on failure", ctx do
      stub_intake(%{@authorize_path => unreachable()})

      capture_log(fn -> EndpointAuthorize.authorize(conn(ctx)) end)

      assert RequestStore.get_source_env_id() == nil
    end
  end

  describe "the hostname it reports and keys its token cache on" do
    test "lowercases it", ctx do
      stub_intake(%{@authorize_path => authorized(), @token_path => minting_token("t")})

      EndpointAuthorize.authorize(conn(ctx, hostname: "API.Example.TEST"))

      assert List.first(authorize_calls()).body["target_hostname"] == "api.example.test"
    end

    # Cowboy, Bandit and Plug.Test.conn/2 all strip the brackets off an IPv6
    # literal before setting conn.host, so this is what a real IPv6 request
    # looks like by the time it reaches this conn -- the conn(ctx, hostname:
    # ...) helper sets :host as a struct field and writes no header, exactly
    # like a real adapter.
    test "re-brackets an IPv6 host that arrived on conn.host without brackets", ctx do
      stub_intake(%{@authorize_path => authorized(), @token_path => minting_token("t")})

      EndpointAuthorize.authorize(conn(ctx, hostname: "2001:db8::1"))

      assert List.first(authorize_calls()).body["target_hostname"] == "[2001:db8::1]"
    end

    test "reports no hostname and authenticates with Basic when the host is unusable", ctx do
      stub_intake(%{@authorize_path => authorized(), @token_path => minting_token("t")})

      EndpointAuthorize.authorize(conn(ctx, hostname: "api.example.test/../evil"))

      call = List.first(authorize_calls())
      assert call.body["target_hostname"] == nil
      assert call.auth == "Basic " <> Base.encode64("cid:csecret")
      assert Enum.filter(intake_calls(), &(&1.path == @token_path)) == []
    end
  end
end
