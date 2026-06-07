defmodule EndPointBlank.Writers.LogWriter do
  @moduledoc """
  Sends structured log messages to the EndPointBlank API.

  Equivalent to `EndPointBlank::Writers::LogWriter` in the Ruby gem.

  ## Usage

      LogWriter.info("Fetching books list")
      LogWriter.error("Something went wrong", %{reason: "timeout"})
  """

  alias EndPointBlank.{Config, Masking, RequestStore, Writers}

  def info(message, data \\ %{}), do: write(message, "info", data)
  def warn(message, data \\ %{}), do: write(message, "warn", data)
  def error(message, data \\ %{}), do: write(message, "error", data)
  def fatal(message, data \\ %{}), do: write(message, "fatal", data)

  defp write(message, level, data) do
    config = Config.get()

    payload = %{
      message: message,
      log_level: level,
      sent_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      app_name: config.app_name,
      uuid: RequestStore.get_uuid(),
      data: data,
      source_application_environment_id: RequestStore.get_source_env_id()
    }

    payload = Masking.apply(payload, :log, Config.masking_rules(), Config.mask_hook())

    payload =
      case RequestStore.get_conn() do
        %Plug.Conn{} = conn ->
          Map.merge(payload, %{stamped_path: conn.request_path, stamped_http_method: conn.method})
        _ ->
          payload
      end

    Writers.write(:logs, config.log_mode, [payload])
  end
end
