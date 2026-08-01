defmodule EndPointBlank.DeprecationHeaders do
  @moduledoc """
  Formats the deprecation facts returned by an authorize call into the standard
  response headers.

    * `Deprecation` — RFC 9745, an Item Structured Header Date: `@1688169599`
    * `Sunset` — RFC 8594, an HTTP-date: `Sat, 31 Dec 2018 23:59:59 GMT`

  RFC 9745 permits a past value ("was deprecated at that date"), which is what
  EndPointBlank emits: deprecation takes effect when it is declared.

  Pure and stateless. The SDK does not know what a lifecycle is — it relays two
  timestamps the portal already decided about, and this turns them into two
  strings.

  Header *names* are lowercase here, unlike the other SDKs. Plug requires it —
  `put_resp_header/3` raises on an uppercase name — and HTTP/2 mandates it on
  the wire anyway. The values are unaffected.
  """

  @deprecation "deprecation"
  @sunset "sunset"

  # Fixed English abbreviations. An HTTP-date is the same in every locale, and
  # these must not follow whatever the node's locale happens to be.
  @days {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
  @months {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

  @doc """
  Header name/value pairs for a deprecation block; `[]` when there is nothing
  to say.
  """
  def build(deprecation) when is_map(deprecation) do
    []
    |> maybe_put(@deprecation, deprecation["deprecated_at"], &deprecation_value/1)
    |> maybe_put(@sunset, deprecation["sunset_at"], &sunset_value/1)
    |> Enum.reverse()
  end

  def build(_), do: []

  @doc """
  Puts the headers on a `Plug.Conn`, if there are any.

  Never raises into the provider's response path: a malformed timestamp is a
  bug worth no header, not a 500 on a request that already succeeded. A header
  the application already set is left alone — it has said something more
  specific than we know.
  """
  def put_headers(conn, deprecation) do
    Enum.reduce(build(deprecation), conn, fn {name, value}, acc ->
      case Plug.Conn.get_resp_header(acc, name) do
        [] -> Plug.Conn.put_resp_header(acc, name, value)
        _ -> acc
      end
    end)
  rescue
    error ->
      require Logger
      Logger.warning("[EndPointBlank] Failed to set deprecation headers: #{inspect(error)}")
      conn
  end

  @doc "`@1688169599` — no quotes, no sub-second precision."
  def deprecation_value(%DateTime{} = dt), do: "@#{DateTime.to_unix(dt)}"

  @doc "`Sat, 31 Dec 2018 23:59:59 GMT` — zero-padded day, always GMT."
  def sunset_value(%DateTime{} = dt) do
    utc = DateTime.shift_zone!(dt, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)
    day = elem(@days, Date.day_of_week(DateTime.to_date(utc)) - 1)
    month = elem(@months, utc.month - 1)

    "#{day}, #{pad(utc.day)} #{month} #{utc.year} " <>
      "#{pad(utc.hour)}:#{pad(utc.minute)}:#{pad(utc.second)} GMT"
  end

  defp maybe_put(acc, name, value, formatter) do
    case parse(value) do
      nil -> acc
      dt -> [{name, formatter.(dt)} | acc]
    end
  end

  # Types are matched rather than coerced. An integer is readable as a Unix
  # timestamp, so accepting one would turn a nonsense value into a
  # plausible-looking header — the one outcome worse than no header at all.
  defp parse(%DateTime{} = dt), do: dt

  defp parse(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse(_), do: nil

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
