defmodule EndPointBlank.Management.ManagedClients do
  @moduledoc """
  Managed clients: client organizations you create
  (`EndPointBlank.Management.Clients.create/3` with `managed: true`) and run
  for your customer until they claim them.

  Act on one's applications, environments and credentials with
  `EndPointBlank.Management.for_managed_client/2`:

      customer = EndPointBlank.Management.for_managed_client(mgmt, client_id)
      {:ok, app} = EndPointBlank.Management.Applications.create(customer, %{name: "billing"})

  This module sends the claim invite that hands one over.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.Request

  @doc """
  Emails `email` an invite to claim managed client `client_id`
  (`POST /api/v1/clients/:client_id/claim_invites`). Answers
  `%{"client_id", "email", "sent_at", "expires_at"}`. Refused with
  `"client_not_managed"` when the client is not an unclaimed managed client of
  yours. Options: `idempotency_key:`.
  """
  @spec claim_invite(Management.t(), String.t(), String.t(), keyword()) ::
          Management.result(map())
  def claim_invite(%Management{} = client, client_id, email, opts \\ []) do
    client
    |> Request.post(:organization, ["clients", client_id, "claim_invites"], %{email: email}, opts)
    |> Request.data()
  end
end
