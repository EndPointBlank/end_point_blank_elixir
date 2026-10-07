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

  This module sends the claim invite that hands one over, and mints the
  portal sign-in link its owner uses until they claim it.
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

  @doc """
  Mints a single-use link that signs the owner of managed client `client_id`
  in to its EndPointBlank portal
  (`POST /api/v1/clients/:client_id/portal_sessions`). Answers
  `%{"url", "expires_at"}`.

  The link expires 60 seconds after it is minted and works once, so mint it
  when the user clicks and redirect their browser to it; never render it into
  a page or send it in an email. Only for an unclaimed managed client of yours
  that is still open to claims: anything else is refused with 422. Options:
  `idempotency_key:`, and `return_url:`, a URL registered under your
  organization's claim return URLs (byte for byte) that the portal links back
  to; any other URL is refused.
  """
  @spec create_portal_session(Management.t(), String.t(), keyword()) ::
          Management.result(map())
  def create_portal_session(%Management{} = client, client_id, opts \\ []) do
    {return_url, opts} = Keyword.pop(opts, :return_url)
    body = if return_url, do: %{return_url: return_url}

    client
    |> Request.post(:organization, ["clients", client_id, "portal_sessions"], body, opts)
    |> Request.data()
  end
end
