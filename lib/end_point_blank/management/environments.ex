defmodule EndPointBlank.Management.Environments do
  @moduledoc """
  `/api/v1/environments`: your deployment environments (production, staging,
  ...), or, through `EndPointBlank.Management.for_managed_client/2`, a managed
  client's.

  An environment is `%{"id", "name", "domain", "is_default", "production",
  "synced_at", "inserted_at", "updated_at"}`. The production environment
  cannot be changed or deleted (`"protected"`).
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @doc "One page of environments. Options: `limit:`, `after:`."
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :managed, ["environments"], opts)

  @doc "Every environment, a page at a time. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :managed, ["environments"], opts)

  @doc "One environment."
  @spec get(Management.t(), String.t()) :: Management.result(map())
  def get(%Management{} = client, id),
    do: client |> Request.get(:managed, ["environments", id]) |> Request.data()

  @doc """
  Creates an environment. `attrs`: `name` and `domain` (required),
  `is_default`. Options: `idempotency_key:`.
  """
  @spec create(Management.t(), map() | keyword(), keyword()) :: Management.result(map())
  def create(%Management{} = client, attrs, opts \\ []),
    do: client |> Request.post(:managed, ["environments"], attrs, opts) |> Request.data()

  @doc "Updates an environment. `attrs`: `name`, `domain`, `is_default`."
  @spec update(Management.t(), String.t(), map() | keyword()) :: Management.result(map())
  def update(%Management{} = client, id, attrs),
    do: client |> Request.patch(:managed, ["environments", id], attrs) |> Request.data()

  @doc """
  Deletes an environment: `%{"id", "deleted" => true}`. Refused with
  `"has_dependents"` while grants or credentials depend on it.
  """
  @spec delete(Management.t(), String.t()) :: Management.result(map())
  def delete(%Management{} = client, id),
    do: client |> Request.delete(:managed, ["environments", id]) |> Request.data()
end
