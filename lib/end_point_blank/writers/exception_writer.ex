defmodule EndPointBlank.Writers.ExceptionWriter do
  @moduledoc "Sends unhandled exception details to the EndPointBlank API."

  alias EndPointBlank.{Config, RequestStore, Writers}

  @doc "Sends `exception` with its `stacktrace` to the errors endpoint."
  def write(exception, stacktrace \\ []) do
    config = Config.get()

    payload = %{
      app_name: config.app_name,
      uuid: RequestStore.get_uuid(),
      message: Exception.message(exception),
      stacktrace: Enum.map(stacktrace, &Exception.format_stacktrace_entry/1),
      sent_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source_application_environment_id: RequestStore.get_source_env_id()
    }

    Writers.write(:errors, config.log_mode, [payload])
  end
end
