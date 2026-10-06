defmodule EndPointBlank.Writers do
  @moduledoc "Dispatch helper — routes payloads to the direct or delayed writer."

  alias EndPointBlank.Writers.{DirectWriter, DelayedWriter}

  # Headers no request or response record ever carries, lower-cased and matched
  # in any letter case (sc-1470). A request record used to carry every inbound
  # header, so a caller's `authorization: Basic client_id:secret` or bearer
  # token, a proxy credential and its session cookie landed in the provider's
  # request log unless the provider had written a masking rule for them; a
  # response record likewise carried `set-cookie`. The writers drop these
  # before masking runs, rather than mask them, so no rule and no mask hook can
  # bring them back.
  @sensitive_headers ~w(authorization proxy-authorization cookie set-cookie)

  def write(url_key, :direct, payloads), do: DirectWriter.write(url_key, payloads)
  def write(url_key, :delayed, payloads), do: DelayedWriter.write(url_key, payloads)

  @doc "The lower-cased names of the headers a record never carries (sc-1470)."
  def sensitive_headers, do: @sensitive_headers

  @doc """
  Turns a `Plug.Conn` header list into the map a record sends: every header but
  the ones in `sensitive_headers/0`, whatever their letter case.
  """
  def reportable_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(name) in @sensitive_headers end)
    |> Map.new()
  end
end
