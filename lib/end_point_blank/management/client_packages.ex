defmodule EndPointBlank.Management.ClientPackages do
  @moduledoc """
  `/api/v1/clients/:client_id/packages`: the API packages a client holds from
  you, or, for a client that has not accepted its invite yet, is set up to get
  when it does.

  An assignment is `%{"id", "api_package_id", "api_package_name",
  "environment_id", "status" => "active" | "pending" | "refused", "refusal",
  "inserted_at", "updated_at"}`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of a client's assignments. Options: `limit:`, `after:`."
  @spec list(Management.t(), String.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, client_id, opts \\ []),
    do: Request.page(client, :organization, ["clients", client_id, "packages"], opts)

  @doc "Every assignment of a client. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, client_id, opts \\ []),
    do: Request.stream(client, :organization, ["clients", client_id, "packages"], opts)

  @doc """
  Assigns an API package to a client. `attrs`: `api_package_id` and
  `environment_id` (required). Refused with `"already_assigned"`, or
  `"nothing_published_in_environment"` when the package would give the client
  no grant there. Options: `idempotency_key:`.
  """
  @spec create(Management.t(), String.t(), map() | keyword(), keyword()) ::
          Management.result(map())
  def create(%Management{} = client, client_id, attrs, opts \\ []) do
    client
    |> Request.post(:organization, ["clients", client_id, "packages"], attrs, opts)
    |> Request.data()
  end

  @doc "Moves assignment `id` to another environment. `attrs`: `environment_id`."
  @spec update(Management.t(), String.t(), String.t(), map() | keyword()) ::
          Management.result(map())
  def update(%Management{} = client, client_id, id, attrs) do
    client
    |> Request.patch(:organization, ["clients", client_id, "packages", id], attrs)
    |> Request.data()
  end

  @doc "Un-assigns a package: `%{\"id\", \"deleted\" => true}`."
  @spec delete(Management.t(), String.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, client_id, id) do
    client
    |> Request.delete(:organization, ["clients", client_id, "packages", id])
    |> Request.data()
  end
end
