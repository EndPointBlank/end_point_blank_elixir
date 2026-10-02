defmodule EndPointBlank.Management.Organization do
  @moduledoc """
  `GET /api/v1/organization`: the organization your management key belongs
  to, and the key's name and scope.
  """

  alias EndPointBlank.Management
  alias EndPointBlank.Management.Request

  @doc """
  The key's organization:
  `%{"id", "name", "domain", "slug", "key" => %{"name", "scope"}}`.
  """
  @spec get(Management.t()) :: Management.result(map())
  def get(%Management{} = client),
    do: client |> Request.get(:organization, ["organization"]) |> Request.data()
end
