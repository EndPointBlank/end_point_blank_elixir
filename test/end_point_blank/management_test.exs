defmodule EndPointBlank.ManagementTest do
  # async: false only for the runtime-credentials test, which sets the global
  # EndPointBlank config; every other test owns its own stub.
  use ExUnit.Case, async: false

  alias EndPointBlank.Config
  alias EndPointBlank.Management

  alias EndPointBlank.Management.{
    ApiPackages,
    ApplicationEnvironments,
    Applications,
    ClientGrants,
    ClientPackages,
    Clients,
    Credentials,
    Endpoints,
    Environments,
    Error,
    ManagedClients,
    Organization,
    Page
  }

  @key "epb_mk_test_0123456789abcdef"
  @base_url "https://portal.test"

  # -- stub ------------------------------------------------------------------

  # A plug that answers each request with the next of `responses` and sends
  # the request to the test as {:request, map}. A response is
  # `{status, json_body}`, `{status, json_body, headers}`,
  # `{:raw, status, content_type, text}` or `:transport_error`.
  defp stub(responses) do
    test_pid = self()
    {:ok, queue} = Agent.start_link(fn -> responses end)

    fn conn ->
      send(test_pid, {:request, recorded(conn)})

      next =
        Agent.get_and_update(queue, fn
          [next | rest] -> {next, rest}
          [] -> {:exhausted, []}
        end)

      case next do
        :transport_error ->
          Req.Test.transport_error(conn, :timeout)

        {:raw, status, content_type, text} ->
          conn
          |> Plug.Conn.put_resp_content_type(content_type)
          |> Plug.Conn.send_resp(status, text)

        {status, body} ->
          respond(conn, status, body, [])

        {status, body, headers} ->
          respond(conn, status, body, headers)

        :exhausted ->
          respond(conn, 418, %{"error" => %{"code" => "stub_exhausted", "message" => "x"}}, [])
      end
    end
  end

  defp respond(conn, status, body, headers) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp recorded(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    headers = Map.new(conn.req_headers)

    %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_params,
      body: body_of(conn, headers),
      headers: headers
    }
  end

  defp body_of(conn, headers) do
    cond do
      not String.starts_with?(headers["content-type"] || "", "application/json") ->
        nil

      match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)
        Jason.decode!(raw)

      true ->
        conn.body_params
    end
  end

  defp client(responses, opts \\ []) do
    test_pid = self()

    [
      key: @key,
      base_url: @base_url,
      req_options: [plug: stub(responses)],
      sleep: fn ms -> send(test_pid, {:slept, ms}) end
    ]
    |> Keyword.merge(opts)
    |> Management.new()
  end

  defp next_request do
    assert_received {:request, request}
    request
  end

  defp error(status, code, message \\ "refused", details \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if details, do: Map.put(error, "details", details), else: error
    {status, %{"error" => error}}
  end

  defp one(data, status \\ 200), do: {status, %{"data" => data}}
  defp page(data, next_cursor \\ nil), do: {200, %{"data" => data, "next_cursor" => next_cursor}}
  defp deleted(id), do: one(%{"id" => id, "deleted" => true})

  # -- construction ------------------------------------------------------------

  describe "new/1" do
    test "defaults the base URL and trims a trailing slash" do
      assert Management.new(key: @key).base_url == "https://app.endpointblank.com"

      assert Management.new(key: @key, base_url: "http://localhost:4000/").base_url ==
               "http://localhost:4000"
    end

    test "refuses a key that is not a management key, without repeating it" do
      for key <- [nil, "", "epb_mk_", "some-runtime-secret", 42] do
        error = assert_raise ArgumentError, fn -> Management.new(key: key) end
        assert error.message =~ "epb_mk_"
        refute error.message =~ "some-runtime-secret"
      end

      assert_raise ArgumentError, fn -> Management.new([]) end
    end

    test "refuses a key with a character a key never has, without repeating it" do
      for key <- ["epb_mk_abc\n", "epb_mk_a b", "epb_mk_abc\r\n", "epb_mk_\u00e9", "epb_mk_a\0b"] do
        error = assert_raise ArgumentError, fn -> Management.new(key: key) end
        refute error.message =~ key
        refute error.message =~ String.trim(key)
      end

      assert %Management{} = Management.new(key: "epb_mk_AZaz09_-")
    end

    test "receive_timeout must be positive" do
      assert_raise ArgumentError, fn -> Management.new(key: @key, receive_timeout: 0) end
    end

    test "req_options cannot replace the Bearer key" do
      mgmt =
        client([one(%{})],
          req_options: [
            plug: stub([one(%{})]),
            auth: {:bearer, "other"},
            headers: [{"authorization", "Basic x"}]
          ]
        )

      assert {:ok, _} = Organization.get(mgmt)
      assert next_request().headers["authorization"] == "Bearer " <> @key
    end

    test "refuses a base URL that is not absolute http(s)" do
      assert_raise ArgumentError, fn ->
        Management.new(key: @key, base_url: "app.endpointblank.com")
      end

      assert_raise ArgumentError, fn -> Management.new(key: @key, base_url: "ftp://x.test") end
    end

    test "inspect never shows the key" do
      client = Management.new(key: @key)
      refute inspect(client) =~ @key
      refute inspect(Management.for_managed_client(client, "c1")) =~ @key
      assert inspect(client) =~ "https://app.endpointblank.com"
    end
  end

  # -- headers -------------------------------------------------------------------

  describe "headers" do
    setup do
      on_exit(fn -> Config.reset() end)
    end

    test "sends the management key as Bearer and never the runtime credential" do
      EndPointBlank.configure(client_id: "runtime-cid", client_secret: "runtime-csecret")

      assert {:ok, %{"slug" => "acme"}} = Organization.get(client([one(%{"slug" => "acme"})]))

      request = next_request()
      assert request.headers["authorization"] == "Bearer " <> @key
      assert request.headers["accept"] == "application/json"
      assert request.headers["user-agent"] =~ "end_point_blank_elixir/"

      for {_name, value} <- request.headers do
        refute value =~ "runtime-cid"
        refute value =~ "runtime-csecret"
        refute value =~ Base.encode64("runtime-cid:runtime-csecret")
      end
    end

    test "sends Content-Type JSON on a body, and no Idempotency-Key on GET, PATCH or DELETE" do
      mgmt = client([one(%{}), one(%{}), deleted("p1")])

      assert {:ok, _} = ApiPackages.get(mgmt, "p1")
      refute Map.has_key?(next_request().headers, "idempotency-key")

      assert {:ok, _} = ApiPackages.update(mgmt, "p1", %{name: "Gold"})
      patch = next_request()
      assert patch.headers["content-type"] =~ "application/json"
      refute Map.has_key?(patch.headers, "idempotency-key")

      assert {:ok, _} = ApiPackages.delete(mgmt, "p1")
      refute Map.has_key?(next_request().headers, "idempotency-key")
    end
  end

  # -- resources -------------------------------------------------------------------

  describe "Organization" do
    test "get/1" do
      assert {:ok, %{"id" => "o1"}} = Organization.get(client([one(%{"id" => "o1"})]))
      assert %{method: "GET", path: "/api/v1/organization"} = next_request()
    end
  end

  describe "ApiPackages" do
    test "list/2 sends limit and after and answers a page" do
      mgmt = client([page([%{"id" => "p1"}], "cur2")])

      assert {:ok, %Page{data: [%{"id" => "p1"}], next_cursor: "cur2"}} =
               ApiPackages.list(mgmt, limit: 1, after: "cur1")

      assert %{method: "GET", path: "/api/v1/api_packages", query: query} = next_request()
      assert query == %{"limit" => "1", "after" => "cur1"}
    end

    test "get, create, update and delete" do
      mgmt =
        client([
          one(%{"id" => "p1"}),
          one(%{"id" => "p1", "name" => "Gold"}, 201),
          one(%{"id" => "p1", "name" => "Platinum"}),
          deleted("p1")
        ])

      assert {:ok, %{"id" => "p1"}} = ApiPackages.get(mgmt, "p1")
      assert %{method: "GET", path: "/api/v1/api_packages/p1"} = next_request()

      assert {:ok, %{"name" => "Gold"}} = ApiPackages.create(mgmt, name: "Gold")

      assert %{method: "POST", path: "/api/v1/api_packages", body: %{"name" => "Gold"}} =
               next_request()

      assert {:ok, %{"name" => "Platinum"}} = ApiPackages.update(mgmt, "p1", %{name: "Platinum"})

      assert %{method: "PATCH", path: "/api/v1/api_packages/p1", body: %{"name" => "Platinum"}} =
               next_request()

      assert {:ok, %{"deleted" => true}} = ApiPackages.delete(mgmt, "p1")
      assert %{method: "DELETE", path: "/api/v1/api_packages/p1"} = next_request()
    end

    test "package endpoints: list, add (with warnings) and remove" do
      warning = %{"code" => "assignment_derives_nothing", "message" => "m"}

      mgmt =
        client([
          page([%{"id" => "a1"}]),
          {201, %{"data" => %{"id" => "a1"}, "warnings" => [warning]}},
          {200, %{"data" => %{"id" => "a1", "deleted" => true}, "warnings" => []}}
        ])

      assert {:ok, %Page{data: [%{"id" => "a1"}], next_cursor: nil}} =
               ApiPackages.list_endpoints(mgmt, "p1")

      assert %{method: "GET", path: "/api/v1/api_packages/p1/endpoints"} = next_request()

      attrs = %{application_id: "app1", endpoint_id: "e1", environment_id: "env1"}

      assert {:ok, %{data: %{"id" => "a1"}, warnings: [^warning]}} =
               ApiPackages.add_endpoint(mgmt, "p1", attrs)

      assert %{method: "POST", path: "/api/v1/api_packages/p1/endpoints", body: body} =
               next_request()

      assert body == %{
               "application_id" => "app1",
               "endpoint_id" => "e1",
               "environment_id" => "env1"
             }

      assert {:ok, %{data: %{"deleted" => true}, warnings: []}} =
               ApiPackages.remove_endpoint(mgmt, "p1", "a1")

      assert %{method: "DELETE", path: "/api/v1/api_packages/p1/endpoints/a1"} = next_request()
    end
  end

  describe "Endpoints" do
    test "list/2 sends its filters" do
      mgmt = client([page([%{"id" => "e1"}])])

      assert {:ok, %Page{data: [%{"id" => "e1"}]}} =
               Endpoints.list(mgmt, application_id: "app1", version: "1.0.0", ignored: "x")

      assert %{method: "GET", path: "/api/v1/endpoints", query: query} = next_request()
      assert query == %{"application_id" => "app1", "version" => "1.0.0"}
    end
  end

  describe "Clients" do
    test "list, get, create (invite with packages and grants) and delete" do
      mgmt =
        client([
          page([%{"id" => "c1"}]),
          one(%{"id" => "c1"}),
          one(%{"id" => "c2", "status" => "pending", "invite_code" => "inv"}, 201),
          deleted("c1")
        ])

      assert {:ok, %Page{data: [%{"id" => "c1"}]}} = Clients.list(mgmt)
      assert %{method: "GET", path: "/api/v1/clients"} = next_request()

      assert {:ok, %{"id" => "c1"}} = Clients.get(mgmt, "c1")
      assert %{method: "GET", path: "/api/v1/clients/c1"} = next_request()

      attrs = %{
        name: "Acme",
        contacts: [%{email: "a@acme.test", first_name: "A", last_name: "B"}],
        packages: [%{api_package_id: "p1", environment_id: "env1"}],
        grants: [%{target_application_id: "app1", environment_id: "env1"}]
      }

      assert {:ok, %{"invite_code" => "inv"}} = Clients.create(mgmt, attrs)
      assert %{method: "POST", path: "/api/v1/clients", body: body} = next_request()

      assert body == %{
               "name" => "Acme",
               "contacts" => [
                 %{"email" => "a@acme.test", "first_name" => "A", "last_name" => "B"}
               ],
               "packages" => [%{"api_package_id" => "p1", "environment_id" => "env1"}],
               "grants" => [%{"target_application_id" => "app1", "environment_id" => "env1"}]
             }

      assert {:ok, %{"deleted" => true}} = Clients.delete(mgmt, "c1")
      assert %{method: "DELETE", path: "/api/v1/clients/c1"} = next_request()
    end

    test "create/3 with managed: true" do
      mgmt = client([one(%{"id" => "c3", "managed" => true}, 201)])

      assert {:ok, %{"managed" => true}} =
               Clients.create(mgmt, %{name: "Customer", managed: true})

      assert %{body: %{"name" => "Customer", "managed" => true}} = next_request()
    end
  end

  describe "ClientPackages" do
    test "list, create, update and delete" do
      mgmt =
        client([
          page([%{"id" => "as1"}]),
          one(%{"id" => "as1", "status" => "active"}, 201),
          one(%{"id" => "as1", "environment_id" => "env2"}),
          deleted("as1")
        ])

      assert {:ok, %Page{data: [_]}} = ClientPackages.list(mgmt, "c1", limit: 10)

      assert %{method: "GET", path: "/api/v1/clients/c1/packages", query: %{"limit" => "10"}} =
               next_request()

      assert {:ok, %{"status" => "active"}} =
               ClientPackages.create(mgmt, "c1", api_package_id: "p1", environment_id: "env1")

      assert %{
               method: "POST",
               path: "/api/v1/clients/c1/packages",
               body: %{"api_package_id" => "p1", "environment_id" => "env1"}
             } = next_request()

      assert {:ok, %{"environment_id" => "env2"}} =
               ClientPackages.update(mgmt, "c1", "as1", %{environment_id: "env2"})

      assert %{
               method: "PATCH",
               path: "/api/v1/clients/c1/packages/as1",
               body: %{"environment_id" => "env2"}
             } = next_request()

      assert {:ok, %{"deleted" => true}} = ClientPackages.delete(mgmt, "c1", "as1")
      assert %{method: "DELETE", path: "/api/v1/clients/c1/packages/as1"} = next_request()
    end
  end

  describe "ClientGrants" do
    test "list, create and delete" do
      mgmt =
        client([
          page([]),
          one(%{"id" => "g1"}, 201),
          one(%{"id" => "g1", "deleted" => true, "still_granted_by_package" => true})
        ])

      assert {:ok, %Page{data: [], next_cursor: nil}} = ClientGrants.list(mgmt, "c1")
      assert %{method: "GET", path: "/api/v1/clients/c1/grants"} = next_request()

      assert {:ok, %{"id" => "g1"}} =
               ClientGrants.create(mgmt, "c1", %{
                 target_application_id: "app1",
                 target_endpoint_id: "e1",
                 environment_id: "env1"
               })

      assert %{method: "POST", path: "/api/v1/clients/c1/grants", body: body} = next_request()

      assert body == %{
               "target_application_id" => "app1",
               "target_endpoint_id" => "e1",
               "environment_id" => "env1"
             }

      assert {:ok, %{"still_granted_by_package" => true}} = ClientGrants.delete(mgmt, "c1", "g1")
      assert %{method: "DELETE", path: "/api/v1/clients/c1/grants/g1"} = next_request()
    end
  end

  describe "Applications" do
    test "list, get, create, update and delete" do
      mgmt =
        client([
          page([%{"id" => "app1"}]),
          one(%{"id" => "app1"}),
          one(%{"id" => "app1", "name" => "billing"}, 201),
          one(%{"id" => "app1", "public" => true}),
          deleted("app1")
        ])

      assert {:ok, %Page{data: [_]}} = Applications.list(mgmt)
      assert %{method: "GET", path: "/api/v1/applications"} = next_request()

      assert {:ok, %{"id" => "app1"}} = Applications.get(mgmt, "app1")
      assert %{method: "GET", path: "/api/v1/applications/app1"} = next_request()

      assert {:ok, %{"name" => "billing"}} =
               Applications.create(mgmt, %{
                 name: "billing",
                 environment_base_urls: %{"env1" => "https://billing.example.test"}
               })

      assert %{method: "POST", path: "/api/v1/applications", body: body} = next_request()

      assert body == %{
               "name" => "billing",
               "environment_base_urls" => %{"env1" => "https://billing.example.test"}
             }

      assert {:ok, %{"public" => true}} = Applications.update(mgmt, "app1", public: true)

      assert %{method: "PATCH", path: "/api/v1/applications/app1", body: %{"public" => true}} =
               next_request()

      assert {:ok, %{"deleted" => true}} = Applications.delete(mgmt, "app1")
      assert %{method: "DELETE", path: "/api/v1/applications/app1"} = next_request()
    end
  end

  describe "ApplicationEnvironments" do
    test "list, create and delete" do
      mgmt = client([page([]), one(%{"id" => "ae1"}, 201), deleted("ae1")])

      assert {:ok, %Page{data: []}} = ApplicationEnvironments.list(mgmt, "app1")
      assert %{method: "GET", path: "/api/v1/applications/app1/environments"} = next_request()

      assert {:ok, %{"id" => "ae1"}} =
               ApplicationEnvironments.create(mgmt, "app1", %{
                 environment_id: "env1",
                 base_url: "https://api.example.test"
               })

      assert %{
               method: "POST",
               path: "/api/v1/applications/app1/environments",
               body: %{"environment_id" => "env1", "base_url" => "https://api.example.test"}
             } = next_request()

      assert {:ok, %{"deleted" => true}} = ApplicationEnvironments.delete(mgmt, "app1", "ae1")

      assert %{method: "DELETE", path: "/api/v1/applications/app1/environments/ae1"} =
               next_request()
    end
  end

  describe "Environments" do
    test "list, get, create, update and delete" do
      mgmt =
        client([
          page([%{"id" => "env1"}]),
          one(%{"id" => "env1"}),
          one(%{"id" => "env2"}, 201),
          one(%{"id" => "env2", "name" => "qa"}),
          deleted("env2")
        ])

      assert {:ok, %Page{data: [_]}} = Environments.list(mgmt)
      assert %{method: "GET", path: "/api/v1/environments"} = next_request()

      assert {:ok, %{"id" => "env1"}} = Environments.get(mgmt, "env1")
      assert %{method: "GET", path: "/api/v1/environments/env1"} = next_request()

      assert {:ok, %{"id" => "env2"}} =
               Environments.create(mgmt, %{name: "staging", domain: "staging.example.test"})

      assert %{
               method: "POST",
               path: "/api/v1/environments",
               body: %{"name" => "staging", "domain" => "staging.example.test"}
             } = next_request()

      assert {:ok, %{"name" => "qa"}} = Environments.update(mgmt, "env2", %{name: "qa"})

      assert %{method: "PATCH", path: "/api/v1/environments/env2", body: %{"name" => "qa"}} =
               next_request()

      assert {:ok, %{"deleted" => true}} = Environments.delete(mgmt, "env2")
      assert %{method: "DELETE", path: "/api/v1/environments/env2"} = next_request()
    end
  end

  describe "Credentials" do
    test "list (with filter), get, create, rotate and delete; the secret comes back" do
      mgmt =
        client([
          page([%{"id" => "cr1", "secret_last_4" => "abcd"}]),
          one(%{"id" => "cr1"}),
          one(%{"id" => "cr1", "client_id" => "acme.x", "client_secret" => "s3cret-1"}, 201),
          one(%{"id" => "cr1", "client_secret" => "s3cret-2"}),
          deleted("cr1"),
          deleted("cr1")
        ])

      assert {:ok, %Page{data: [_]}} = Credentials.list(mgmt, application_environment_id: "ae1")

      assert %{
               method: "GET",
               path: "/api/v1/credentials",
               query: %{"application_environment_id" => "ae1"}
             } = next_request()

      assert {:ok, %{"id" => "cr1"}} = Credentials.get(mgmt, "cr1")
      assert %{method: "GET", path: "/api/v1/credentials/cr1"} = next_request()

      assert {:ok, %{"client_secret" => "s3cret-1"}} =
               Credentials.create(mgmt, %{application_environment_id: "ae1"})

      assert %{
               method: "POST",
               path: "/api/v1/credentials",
               body: %{"application_environment_id" => "ae1"}
             } = next_request()

      assert {:ok, %{"client_secret" => "s3cret-2"}} = Credentials.rotate(mgmt, "cr1")
      rotate = next_request()
      assert %{method: "POST", path: "/api/v1/credentials/cr1/rotate", body: nil} = rotate
      assert is_binary(rotate.headers["idempotency-key"])

      assert {:ok, %{"deleted" => true}} = Credentials.delete(mgmt, "cr1")
      assert %{method: "DELETE", path: "/api/v1/credentials/cr1"} = next_request()

      assert {:ok, %{"deleted" => true}} = Credentials.revoke(mgmt, "cr1")
      assert %{method: "DELETE", path: "/api/v1/credentials/cr1"} = next_request()
    end
  end

  describe "managed clients" do
    test "claim_invite/4" do
      mgmt = client([one(%{"client_id" => "c1", "email" => "owner@customer.test"}, 201)])

      assert {:ok, %{"email" => "owner@customer.test"}} =
               ManagedClients.claim_invite(mgmt, "c1", "owner@customer.test")

      assert %{
               method: "POST",
               path: "/api/v1/clients/c1/claim_invites",
               body: %{"email" => "owner@customer.test"}
             } = next_request()
    end

    test "for_managed_client/2 scopes applications, environments and credentials" do
      mgmt =
        client([
          one(%{"id" => "app1"}, 201),
          one(%{"id" => "env1"}, 201),
          one(%{"id" => "ae1"}, 201),
          one(%{"id" => "cr1", "client_secret" => "s"}, 201),
          one(%{"id" => "cr1", "client_secret" => "s2"}),
          page([]),
          deleted("cr1")
        ])

      customer = Management.for_managed_client(mgmt, "c9")

      assert {:ok, _} = Applications.create(customer, %{name: "billing"})
      assert %{method: "POST", path: "/api/v1/clients/c9/applications"} = next_request()

      assert {:ok, _} = Environments.create(customer, %{name: "production"})
      assert %{method: "POST", path: "/api/v1/clients/c9/environments"} = next_request()

      assert {:ok, _} =
               ApplicationEnvironments.create(customer, "app1", %{
                 environment_id: "env1",
                 base_url: "https://api.customer.test"
               })

      assert %{method: "POST", path: "/api/v1/clients/c9/applications/app1/environments"} =
               next_request()

      assert {:ok, _} = Credentials.create(customer, %{application_environment_id: "ae1"})
      assert %{method: "POST", path: "/api/v1/clients/c9/credentials"} = next_request()

      assert {:ok, _} = Credentials.rotate(customer, "cr1")
      assert %{method: "POST", path: "/api/v1/clients/c9/credentials/cr1/rotate"} = next_request()

      assert {:ok, _} = Credentials.list(customer)
      assert %{method: "GET", path: "/api/v1/clients/c9/credentials"} = next_request()

      assert {:ok, _} = Credentials.delete(customer, "cr1")
      assert %{method: "DELETE", path: "/api/v1/clients/c9/credentials/cr1"} = next_request()
    end

    test "a managed-client view refuses organization-only calls without a request" do
      customer = Management.for_managed_client(client([]), "c9")

      assert {:error, %Error{code: "not_available_for_managed_client", status: nil}} =
               ApiPackages.list(customer)

      assert {:error, %Error{code: "not_available_for_managed_client"}} =
               Clients.create(customer, %{name: "x"})

      assert {:error, %Error{code: "not_available_for_managed_client"}} =
               Organization.get(customer)

      refute_received {:request, _}
    end
  end

  describe "paths" do
    test "ids are percent-encoded into one segment" do
      mgmt = client([one(%{})])
      assert {:ok, _} = Clients.get(mgmt, "a/b c")
      assert %{path: "/api/v1/clients/a%2Fb%20c"} = next_request()
    end

    test "an empty or non-string id is refused without a request" do
      mgmt = client([])
      assert {:error, %Error{code: "invalid_request"}} = Clients.get(mgmt, "")
      assert {:error, %Error{code: "invalid_request"}} = ClientGrants.list(mgmt, nil)
      refute_received {:request, _}
    end

    test "dot-segment ids are refused without a request" do
      mgmt = client([])

      assert {:error, %Error{code: "invalid_request"}} =
               ApiPackages.remove_endpoint(mgmt, "p1", "..")

      assert {:error, %Error{code: "invalid_request"}} = ClientPackages.delete(mgmt, "c1", "..")

      assert {:error, %Error{code: "invalid_request"}} =
               ApplicationEnvironments.delete(mgmt, "app1", "..")

      assert {:error, %Error{code: "invalid_request"}} = Applications.get(mgmt, ".")
      assert {:error, %Error{code: "invalid_request"}} = Clients.get(mgmt, "...")

      for id <- ["..", "."] do
        customer = Management.for_managed_client(mgmt, id)
        assert {:error, %Error{code: "invalid_request"}} = Credentials.list(customer)

        assert {:error, %Error{code: "invalid_request"}} =
                 Applications.create(customer, %{name: "x"})
      end

      refute_received {:request, _}
    end

    test "an id with dots among other characters is still sent" do
      mgmt = client([one(%{})])
      assert {:ok, _} = Clients.get(mgmt, "a..b")
      assert %{path: "/api/v1/clients/a..b"} = next_request()
    end
  end

  # -- pagination ----------------------------------------------------------------

  describe "pagination" do
    test "stream/2 follows next_cursor over every page, lazily" do
      mgmt =
        client([
          page([%{"id" => "1"}, %{"id" => "2"}], "c2"),
          page([%{"id" => "3"}], "c3"),
          page([%{"id" => "4"}])
        ])

      stream = Clients.stream(mgmt, limit: 2)
      refute_received {:request, _}

      assert Enum.map(stream, & &1["id"]) == ["1", "2", "3", "4"]

      assert %{query: %{"limit" => "2"} = first} = next_request()
      refute Map.has_key?(first, "after")
      assert %{query: %{"limit" => "2", "after" => "c2"}} = next_request()
      assert %{query: %{"limit" => "2", "after" => "c3"}} = next_request()
      refute_received {:request, _}
    end

    test "a stream stops fetching once enough items are taken" do
      mgmt = client([page([%{"id" => "1"}, %{"id" => "2"}], "c2"), page([%{"id" => "3"}])])

      assert [%{"id" => "1"}] = mgmt |> ApiPackages.stream() |> Enum.take(1)
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "a stream raises the error of a page that fails" do
      mgmt = client([page([%{"id" => "1"}], "c2"), error(400, "invalid_pagination")])

      assert_raise Error, ~r/invalid_pagination/, fn ->
        mgmt |> Environments.stream() |> Enum.to_list()
      end
    end

    test "limit must be 1 to 100, checked before any request" do
      mgmt = client([])

      for limit <- [0, 101, "50", -1] do
        assert {:error, %Error{code: "invalid_request"}} = Clients.list(mgmt, limit: limit)
      end

      refute_received {:request, _}
    end
  end

  # -- idempotency -------------------------------------------------------------------

  describe "idempotency" do
    test "every POST gets a fresh UUID v4 Idempotency-Key" do
      mgmt = client([one(%{}, 201), one(%{}, 201)])

      assert {:ok, _} = ApiPackages.create(mgmt, %{name: "a"})
      assert {:ok, _} = ApiPackages.create(mgmt, %{name: "b"})

      first = next_request().headers["idempotency-key"]
      second = next_request().headers["idempotency-key"]

      uuid_v4 = ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      assert first =~ uuid_v4
      assert second =~ uuid_v4
      refute first == second
    end

    test "a caller's Idempotency-Key is sent as given" do
      mgmt = client([one(%{}, 201)])
      assert {:ok, _} = Clients.create(mgmt, %{name: "Acme"}, idempotency_key: "invite-acme-1")
      assert next_request().headers["idempotency-key"] == "invite-acme-1"
    end

    test "a retried POST sends the same key" do
      mgmt =
        client([error(503, "intake_unavailable"), :transport_error, one(%{"id" => "cr1"}, 201)])

      assert {:ok, %{"id" => "cr1"}} =
               Credentials.create(mgmt, %{application_environment_id: "ae1"})

      keys = for _ <- 1..3, do: next_request().headers["idempotency-key"]
      assert [key, key, key] = keys
      assert is_binary(key)
    end

    test "idempotency_request_in_progress is retried with the same key" do
      mgmt = client([error(409, "idempotency_request_in_progress"), one(%{"id" => "c1"}, 201)])

      assert {:ok, %{"id" => "c1"}} = Clients.create(mgmt, %{name: "Acme"}, idempotency_key: "k1")
      assert next_request().headers["idempotency-key"] == "k1"
      assert next_request().headers["idempotency-key"] == "k1"
    end

    test "idempotency_replay_unavailable is not retried and says to read the resource" do
      mgmt =
        client([
          {409,
           %{
             "error" => %{"code" => "idempotency_replay_unavailable", "message" => "server text"}
           }, [{"location", "/api/v1/credentials/cr1"}]}
        ])

      assert {:error, %Error{} = error} = Credentials.rotate(mgmt, "cr1", idempotency_key: "k1")
      assert error.code == "idempotency_replay_unavailable"
      assert error.status == 409
      assert error.location == "/api/v1/credentials/cr1"
      assert error.message =~ "Do not retry"
      assert error.message =~ "get or list the credential"

      assert_received {:request, _}
      refute_received {:request, _}
      refute_received {:slept, _}
    end
  end

  # -- retries -----------------------------------------------------------------------

  describe "retries" do
    test "429 waits Retry-After seconds, then succeeds" do
      mgmt =
        client([
          {429, %{"error" => %{"code" => "rate_limited", "message" => "slow down"}},
           [{"retry-after", "7"}]},
          one(%{"id" => "o1"})
        ])

      assert {:ok, %{"id" => "o1"}} = Organization.get(mgmt)
      assert_received {:slept, 7000}
    end

    test "429 is retried for a PATCH too: it was refused before it ran" do
      mgmt =
        client([
          {429, %{"error" => %{"code" => "rate_limited", "message" => "m"}},
           [{"retry-after", "1"}]},
          one(%{"id" => "p1"})
        ])

      assert {:ok, _} = ApiPackages.update(mgmt, "p1", %{name: "x"})
      assert_received {:slept, 1000}
    end

    test "retries are bounded by max_retries and the last error is answered" do
      rate_limited =
        {429, %{"error" => %{"code" => "rate_limited", "message" => "m"}}, [{"retry-after", "2"}]}

      mgmt = client([rate_limited, rate_limited, rate_limited, one(%{})])

      assert {:error, %Error{code: "rate_limited", status: 429, retry_after: 2}} =
               Organization.get(mgmt)

      for _ <- 1..3, do: assert_received({:request, _})
      refute_received {:request, _}
    end

    test "max_retries: 0 turns retries off" do
      mgmt = client([error(503, "audit_unavailable"), one(%{})], max_retries: 0)

      assert {:error, %Error{code: "audit_unavailable", status: 503}} =
               Environments.get(mgmt, "e")

      refute_received {:slept, _}
    end

    test "a Retry-After longer than max_retry_wait_ms is answered, not waited out" do
      mgmt =
        client(
          [
            {429, %{"error" => %{"code" => "rate_limited", "message" => "m"}},
             [{"retry-after", "120"}]},
            one(%{})
          ],
          max_retry_wait_ms: 60_000
        )

      assert {:error, %Error{code: "rate_limited", retry_after: 120}} = Organization.get(mgmt)
      refute_received {:slept, _}
    end

    test "5xx and transport errors are retried for GET and DELETE" do
      mgmt =
        client([
          error(500, "internal_server_error"),
          :transport_error,
          one(%{"id" => "a"}),
          error(503, "intake_unavailable"),
          deleted("cr1")
        ])

      assert {:ok, %{"id" => "a"}} = Applications.get(mgmt, "a")
      assert {:ok, %{"deleted" => true}} = Credentials.delete(mgmt, "cr1")
    end

    test "a PATCH is never retried after a 5xx or a transport error" do
      mgmt = client([error(503, "audit_unavailable"), :transport_error, one(%{})])

      assert {:error, %Error{code: "audit_unavailable"}} =
               Environments.update(mgmt, "e1", %{name: "x"})

      assert {:error, %Error{code: "transport_error", status: nil}} =
               Environments.update(mgmt, "e1", %{name: "x"})

      refute_received {:slept, _}
    end

    test "a 4xx other than 429 and in-progress is not retried" do
      mgmt = client([error(422, "has_dependents"), one(%{})])

      assert {:error, %Error{code: "has_dependents"}} = Applications.delete(mgmt, "app1")
      assert_received {:request, _}
      refute_received {:request, _}
    end
  end

  # -- errors ------------------------------------------------------------------------

  describe "errors" do
    test "404 not_found" do
      mgmt = client([error(404, "not_found", "Not found.")])

      assert {:error, %Error{code: "not_found", status: 404, message: "Not found."}} =
               Clients.get(mgmt, "nope")
    end

    test "422 validation_failed carries details" do
      details = %{"name" => ["can't be blank"]}
      mgmt = client([error(422, "validation_failed", "The request has invalid fields.", details)])

      assert {:error, %Error{code: "validation_failed", status: 422, details: ^details}} =
               ApiPackages.create(mgmt, %{name: ""})
    end

    test "402 plan_limit" do
      mgmt = client([error(402, "plan_limit", "Your plan's limit for this resource is reached.")])

      assert {:error, %Error{code: "plan_limit", status: 402} = error} =
               Clients.create(mgmt, %{name: "x"})

      assert Exception.message(error) =~ "plan_limit, HTTP 402"
    end

    test "an unknown code still surfaces" do
      mgmt = client([error(422, "brand_new_refusal", "Something new.")])

      assert {:error, %Error{code: "brand_new_refusal", message: "Something new."}} =
               Applications.create(mgmt, %{name: "x"})

      refute Error.known_code?("brand_new_refusal")
      assert Error.known_code?("plan_limit")
      assert Error.known_codes()["rate_limited"] == 429
    end

    test "a non-JSON error body still answers an error" do
      mgmt = client([{:raw, 502, "text/html", "<html>Bad gateway</html>"}], max_retries: 0)

      assert {:error, %Error{code: "unexpected_response", status: 502} = error} =
               Organization.get(mgmt)

      refute error.message =~ "Bad gateway"
    end

    test "a transport error answers transport_error with no request data" do
      mgmt = client([:transport_error], max_retries: 0)

      assert {:error, %Error{code: "transport_error", status: nil} = error} =
               Organization.get(mgmt)

      assert error.message =~ "timeout"
      refute inspect(error) =~ @key
    end

    test "an error never carries the key" do
      mgmt = client([error(401, "invalid_key", "The management API key is invalid.")])

      assert {:error, %Error{code: "invalid_key"} = error} = Organization.get(mgmt)
      refute inspect(error) =~ @key
      refute Exception.message(error) =~ @key
    end
  end
end
