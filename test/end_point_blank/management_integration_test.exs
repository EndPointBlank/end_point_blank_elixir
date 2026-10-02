defmodule EndPointBlank.ManagementIntegrationTest do
  # Runs against a real app_portal only when EPB_MGMT_BASE_URL and EPB_MGMT_KEY
  # (a write key) are set; skipped otherwise. It creates what it needs, with a
  # random suffix, and removes it again afterwards.
  #
  #     EPB_MGMT_BASE_URL=http://localhost:4000 EPB_MGMT_KEY=epb_mk_... mix test \
  #       test/end_point_blank/management_integration_test.exs
  use ExUnit.Case, async: false

  alias EndPointBlank.Management

  alias EndPointBlank.Management.{
    ApiPackages,
    ApplicationEnvironments,
    Applications,
    ClientPackages,
    Clients,
    Credentials,
    Endpoints,
    Environments,
    Error,
    Organization,
    Page
  }

  @configured Enum.all?(
                ["EPB_MGMT_BASE_URL", "EPB_MGMT_KEY"],
                &(System.get_env(&1) not in [nil, ""])
              )

  unless @configured do
    @moduletag skip: "set EPB_MGMT_BASE_URL and EPB_MGMT_KEY to run against an app_portal"
  end

  setup do
    {:ok, created} = Agent.start(fn -> %{} end)

    mgmt =
      Management.new(
        key: System.get_env("EPB_MGMT_KEY"),
        base_url: System.get_env("EPB_MGMT_BASE_URL")
      )

    on_exit(fn -> clean_up(mgmt, Agent.get(created, & &1)) end)

    %{mgmt: mgmt, created: created, suffix: Integer.to_string(System.unique_integer([:positive]))}
  end

  test "the management flow from the story", %{mgmt: mgmt, created: created, suffix: suffix} do
    track = fn name, id -> Agent.update(created, &Map.put(&1, name, id)) end

    # Organization
    assert {:ok, %{"id" => _, "key" => %{"scope" => "write"}}} = Organization.get(mgmt)

    # An application deployed to a new environment
    application = ok!(Applications.create(mgmt, %{name: "sdk-it-app-#{suffix}"}))
    track.(:application, application["id"])

    environment = ok!(Environments.create(mgmt, %{name: "sdk-it-env-#{suffix}"}))
    track.(:environment, environment["id"])

    app_env =
      ok!(
        ApplicationEnvironments.create(mgmt, application["id"], %{
          environment_id: environment["id"],
          base_url: "https://sdk-it-#{suffix}.example.com"
        })
      )

    track.(:app_env, {application["id"], app_env["id"]})

    assert {:ok, %Page{data: app_envs}} = ApplicationEnvironments.list(mgmt, application["id"])
    assert Enum.any?(app_envs, &(&1["id"] == app_env["id"]))

    # An API package, with a deployed endpoint when there is one
    package = ok!(ApiPackages.create(mgmt, %{name: "sdk-it-package-#{suffix}"}))
    track.(:package, package["id"])

    case Endpoints.list(mgmt, limit: 1) do
      {:ok, %Page{data: [endpoint | _]}} ->
        result =
          ApiPackages.add_endpoint(mgmt, package["id"], %{
            application_id: endpoint["application_id"],
            endpoint_id: endpoint["id"],
            environment_id: environment["id"]
          })

        case result do
          {:ok, %{data: %{"id" => _}, warnings: warnings}} -> assert is_list(warnings)
          # The endpoint's application may not be deployed to the new environment.
          {:error, %Error{status: 422}} -> :ok
        end

      {:ok, %Page{data: []}} ->
        :ok
    end

    # Invite a client and assign the package, if the plan allows a client
    case Clients.create(mgmt, %{name: "sdk-it-client-#{suffix}"}) do
      {:ok, client} ->
        track.(:client, client["id"])
        assert client["status"] == "pending"

        case ClientPackages.create(mgmt, client["id"], %{
               api_package_id: package["id"],
               environment_id: environment["id"]
             }) do
          {:ok, assignment} ->
            assert assignment["api_package_id"] == package["id"]

          # Nothing is deployed in the new environment, so the package gives nothing.
          {:error, %Error{code: code}} ->
            assert code in ["nothing_published_in_environment", "environment_not_found"]
        end

      {:error, %Error{code: "plan_limit", status: 402}} ->
        :ok
    end

    # A credential: create, read, rotate, revoke
    credential = ok!(Credentials.create(mgmt, %{application_environment_id: app_env["id"]}))
    track.(:credential, credential["id"])
    assert is_binary(credential["client_secret"])

    fetched = ok!(Credentials.get(mgmt, credential["id"]))
    refute Map.has_key?(fetched, "client_secret")

    rotated = ok!(Credentials.rotate(mgmt, credential["id"]))
    assert is_binary(rotated["client_secret"])
    refute rotated["client_secret"] == credential["client_secret"]

    assert {:ok, %{"deleted" => true}} = Credentials.revoke(mgmt, credential["id"])
    track.(:credential, nil)

    # A managed client, with its own application, environment and credential
    case Clients.create(mgmt, %{name: "sdk-it-managed-#{suffix}", managed: true}) do
      {:ok, managed} ->
        track.(:managed_client, managed["id"])
        assert managed["managed"] == true
        customer = Management.for_managed_client(mgmt, managed["id"])

        customer_app = ok!(Applications.create(customer, %{name: "sdk-it-customer-#{suffix}"}))

        customer_env =
          ok!(Environments.create(customer, %{name: "sdk-it-customer-env-#{suffix}"}))

        customer_app_env =
          ok!(
            ApplicationEnvironments.create(customer, customer_app["id"], %{
              environment_id: customer_env["id"],
              base_url: "https://sdk-it-customer-#{suffix}.example.com"
            })
          )

        customer_credential =
          ok!(Credentials.create(customer, %{application_environment_id: customer_app_env["id"]}))

        track.(:managed_credential, {managed["id"], customer_credential["id"]})
        assert is_binary(customer_credential["client_secret"])

        assert {:ok, %{"deleted" => true}} =
                 Credentials.revoke(customer, customer_credential["id"])

        track.(:managed_credential, nil)

        # Not claimed here: a claim invite emails a real address.
        assert {:ok, %{"deleted" => true}} = Clients.delete(mgmt, managed["id"])
        track.(:managed_client, nil)

      {:error, %Error{code: "plan_limit", status: 402}} ->
        :ok
    end
  end

  defp ok!({:ok, value}), do: value

  defp ok!({:error, %Error{} = error}),
    do: flunk("expected {:ok, _}, got: #{Exception.message(error)}")

  # Best effort, in dependency order; a failure here must not hide the test's.
  defp clean_up(mgmt, created) do
    with {client_id, credential_id} <- created[:managed_credential] do
      mgmt |> Management.for_managed_client(client_id) |> Credentials.delete(credential_id)
    end

    if id = created[:managed_client], do: Clients.delete(mgmt, id)
    if id = created[:credential], do: Credentials.delete(mgmt, id)
    if id = created[:client], do: Clients.delete(mgmt, id)
    if id = created[:package], do: ApiPackages.delete(mgmt, id)

    with {application_id, id} <- created[:app_env] do
      ApplicationEnvironments.delete(mgmt, application_id, id)
    end

    if id = created[:application], do: Applications.delete(mgmt, id)
    if id = created[:environment], do: Environments.delete(mgmt, id)
    :ok
  end
end
