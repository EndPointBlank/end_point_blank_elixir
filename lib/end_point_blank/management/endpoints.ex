defmodule EndPointBlank.Management.Endpoints do
  @moduledoc """
  `GET /api/v1/endpoints`: your applications' endpoints, to find the ids
  `EndPointBlank.Management.ApiPackages.add_endpoint/4` takes.

  An endpoint is `%{"id", "application_id", "path", "action", "public",
  "inserted_at", "updated_at"}`.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Page, Request}

  @filters [:application_id, :version]

  @doc """
  One page of endpoints. Options: `limit:`, `after:`, `application_id:`
  (only that application's) and `version:` (only endpoints deployed in an
  application version of that name).
  """
  @spec list(Management.t(), keyword()) :: Management.result(Page.t())
  def list(%Management{} = client, opts \\ []),
    do: Request.page(client, :organization, ["endpoints"], opts, @filters)

  @doc "Every endpoint, with `list/2`'s filters. Raises `EndPointBlank.Management.Error`."
  @spec stream(Management.t(), keyword()) :: Enumerable.t()
  def stream(%Management{} = client, opts \\ []),
    do: Request.stream(client, :organization, ["endpoints"], opts, @filters)
end
