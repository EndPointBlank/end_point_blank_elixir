defmodule EndPointBlank.Management.ManagedClients do
  @moduledoc """
  Managed clients: client organizations you create
  (`EndPointBlank.Management.Clients.create/3` with `managed: true`) and run
  for your customer until they claim them.

  Act on one's applications, environments and credentials with
  `EndPointBlank.Management.for_managed_client/2`:

      customer = EndPointBlank.Management.for_managed_client(mgmt, client_id)
      {:ok, env} =
        EndPointBlank.Management.Environments.create(customer, %{
          name: "staging",
          domain: "staging.customer.example"
        })

      {:ok, app} =
        EndPointBlank.Management.Applications.create(customer, %{
          name: "billing",
          environment_base_urls: %{env["id"] => "https://billing.staging.customer.example"}
        })

  This module sends the claim invite that hands one over.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.Request

  @doc """
  Emails `email` an invite to claim managed client `client_id`
  (`POST /api/v1/clients/:client_id/claim_invites`). Answers
  `%{"client_id", "email", "sent_at", "expires_at"}`. Refused with
  `"client_not_managed"` when the client is not an unclaimed managed client of
  yours. Options: `idempotency_key:`, and `return_to:`, a URL registered under
  your organization's claim return URLs that EndPointBlank sends the user's
  browser back to once they accept (refused with `"return_to_not_registered"`
  otherwise).
  """
  @spec claim_invite(Management.t(), String.t(), String.t(), keyword()) ::
          Management.result(map())
  def claim_invite(%Management{} = client, client_id, email, opts \\ []) do
    {return_to, opts} = Keyword.pop(opts, :return_to)
    body = if return_to, do: %{email: email, return_to: return_to}, else: %{email: email}

    client
    |> Request.post(:organization, ["clients", client_id, "claim_invites"], body, opts)
    |> Request.data()
  end
end
