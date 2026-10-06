defmodule EndPointBlank.RequestStore do
  @moduledoc """
  Per-process storage for request-scoped data.

  Uses the process dictionary so each request process (Phoenix allocates one
  per request) has isolated state — the Elixir equivalent of thread-local
  storage used by the Ruby, Java, and JS libraries.
  """

  import Bitwise

  @uuid_key :epb_uuid
  @source_env_id_key :epb_source_env_id
  @source_organization_id_key :epb_source_organization_id
  @conn_key :epb_conn

  def put_uuid(uuid), do: Process.put(@uuid_key, uuid)
  def get_uuid, do: Process.get(@uuid_key)

  def put_conn(conn), do: Process.put(@conn_key, conn)
  def get_conn, do: Process.get(@conn_key)

  def put_source_env_id(id), do: Process.put(@source_env_id_key, id)
  def get_source_env_id, do: Process.get(@source_env_id_key)

  @doc """
  The calling organization's EndPointBlank id, from intake's `/authorize`
  answer (`data[0].source_organization_id`, sc-1571). nil when intake is older
  than that field or the organization has no id there.
  """
  def get_source_organization_id, do: Process.get(@source_organization_id_key)
  def put_source_organization_id(id), do: Process.put(@source_organization_id_key, id)

  def clear do
    Process.delete(@uuid_key)
    Process.delete(@conn_key)
    Process.delete(@source_env_id_key)
    Process.delete(@source_organization_id_key)
  end

  @doc "Generates a random UUID v4 string."
  def generate_uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [
      hex(a, 8),
      "-",
      hex(b, 4),
      "-4",
      hex(c, 3),
      "-",
      hex(d ||| 0x8000, 4),
      "-",
      hex(e, 12)
    ]
    |> IO.iodata_to_binary()
  end

  defp hex(n, len) do
    n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(len, "0")
  end
end
