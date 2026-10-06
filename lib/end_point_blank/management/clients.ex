defmodule EndPointBlank.Management.Clients do
  @moduledoc """
  `/api/v1/clients`: your clients (the organizations you provide APIs to),
  pending invites and accepted ones.

  A client is `%{"id", "name", "status" => "pending" | "accepted",
  "accepted_at", "managed", "claimed_at", "client_organization",
  "inserted_at", "updated_at"}`, plus `"invite_code"` while it is pending
  (write keys only: whoever redeems it becomes this client, so treat it as a
  secret). `get/2` and `create/3` add `"contacts"` and `"pre_assignments"`.

  What a client holds is `EndPointBlank.Management.ClientPackages` and
  `EndPointBlank.Management.ClientGrants`; a managed client's own
  applications, environments and credentials are reached through
  `EndPointBlank.Management.for_managed_client/2`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of your clients. Options: `limit:`, `after:`."
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :organization, ["clients"], opts)

  @doc "Every client, a page at a time. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :organization, ["clients"], opts)

  @doc "One client."
  @spec get(Management.t(), String.t()) :: Management.result(map())
  def get(%Management{} = client, id),
    do: client |> Request.get(:organization, ["clients", id]) |> Request.data()

  @doc """
  Invites a client, or creates a managed one. Counts against your plan's
  client limit (`"plan_limit"`, HTTP 402).

  `attrs`:

    * `name` (required)
    * `contacts` -- your contacts to share with the client:
      `[%{email:, first_name:, last_name:, title:, phone_number:}]`
    * `packages` -- API packages to assign when the client accepts:
      `[%{api_package_id:, environment_id:}]`
    * `grants` -- direct grants to make when it accepts:
      `[%{target_application_id:, target_endpoint_id:, environment_id:}]`
    * `managed` -- `true` creates the client's organization now, for you to
      run until your customer claims it. Not together with `packages` or
      `grants` (`"invalid_managed"`): assign those afterwards.
    * `owner_email` -- with `managed: true`, the email address of the person
      at your customer who will own the managed client. Change it later with
      `update/3`.

  Options: `idempotency_key:`.
  """
  @spec create(Management.t(), map() | keyword(), keyword()) :: Management.result(map())
  def create(%Management{} = client, attrs, opts \\ []),
    do: client |> Request.post(:organization, ["clients"], attrs, opts) |> Request.data()

  @doc """
  Updates client `id` (`PATCH /api/v1/clients/:id`). `attrs`:

    * `owner_email` -- the email address of the person at your customer who
      will own a managed client.
  """
  @spec update(Management.t(), String.t(), map() | keyword()) :: Management.result(map())
  def update(%Management{} = client, id, attrs),
    do: client |> Request.patch(:organization, ["clients", id], attrs) |> Request.data()

  @doc """
  Removes a client: `%{"id", "deleted" => true}`. With your last accepted
  invite for that organization, also takes away every package and grant it
  holds from you. An unclaimed managed client that still has credentials is
  refused with `"managed_client_has_credentials"`.
  """
  @spec delete(Management.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, id),
    do: client |> Request.delete(:organization, ["clients", id]) |> Request.data()
end
