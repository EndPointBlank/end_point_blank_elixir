defmodule EndPointBlank.Writers.ResponseWriter do
  @moduledoc "Sends response metadata to the EndPointBlank API."

  alias EndPointBlank.{Config, RequestStore, Writers}

  def write(%Plug.Conn{} = conn) do
    config = Config.get()

    payload = %{
      app_name: config.app_name,
      env: config.environment,
      uuid: RequestStore.get_uuid(),
      status: conn.status,
      headers: Map.new(conn.resp_headers),
      body: truncate(conn.resp_body),
      sent_at: utc_now(),
      route: conn.private[:epb_route] || conn.request_path,
      data: %{},
      source_application_environment_id: RequestStore.get_source_env_id()
    }

    Writers.write(:responses, config.log_mode, [payload])
  end

  defp truncate(nil), do: nil

  defp truncate(s) do
    bin = IO.iodata_to_binary(s)
    if byte_size(bin) > 1024, do: binary_part(bin, 0, 1024) <> "...", else: bin
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
