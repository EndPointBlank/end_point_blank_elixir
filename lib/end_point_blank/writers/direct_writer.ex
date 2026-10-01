defmodule EndPointBlank.Writers.DirectWriter do
  @moduledoc "Synchronously POSTs a payload batch to the EndPointBlank API."

  require Logger
  alias EndPointBlank.{Authorization, Http}

  @url_builders %{
    requests: :requests_url,
    responses: :responses_url,
    logs: :logs_url,
    errors: :errors_url
  }

  def write(url_key, payloads) when is_list(payloads) do
    # Own intake, so Basic -- see EndPointBlank.Authorization.intake_header/0.
    # Nothing is sent without both credentials (sc-1469); like every other
    # failure here, that logs and returns rather than raising into the host.
    case Authorization.intake_header() do
      {:ok, auth} ->
        post(url_key, payloads, auth)

      {:error, :missing_credentials} ->
        Logger.warning(
          "[EndPointBlank] Write to #{url_key} not sent: " <>
            Authorization.missing_credentials_message()
        )

        :error
    end
  end

  defp post(url_key, payloads, auth) do
    url = apply(EndPointBlank.Config, @url_builders[url_key] || :errors_url, [])
    body = %{payload: payloads}

    case Http.post(url, body, auth) do
      {:ok, %Req.Response{status: s}} when s in 200..299 ->
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        Logger.warning("[EndPointBlank] Write to #{url_key} failed: status=#{s} body=#{inspect(b)}")
        :error

      {:error, reason} ->
        Logger.warning("[EndPointBlank] Write to #{url_key} error: #{Http.describe_error(reason)}")
        :error
    end
  end
end
