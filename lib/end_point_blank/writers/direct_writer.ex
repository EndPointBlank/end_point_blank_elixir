defmodule EndPointBlank.Writers.DirectWriter do
  @moduledoc "Synchronously POSTs a payload batch to the EndPointBlank API."

  require Logger
  alias EndPointBlank.Authorization

  @url_builders %{
    requests: :requests_url,
    responses: :responses_url,
    logs: :logs_url,
    errors: :errors_url
  }

  def write(url_key, payloads) when is_list(payloads) do
    url = apply(EndPointBlank.Config, @url_builders[url_key] || :errors_url, [])
    auth = Authorization.header()
    body = %{payload: payloads}

    case Req.post(url, json: body, headers: [{"authorization", auth}]) do
      {:ok, %Req.Response{status: s}} when s in 200..299 ->
        :ok

      {:ok, %Req.Response{status: s, body: b}} ->
        Logger.warning("[EndPointBlank] Write to #{url_key} failed: status=#{s} body=#{inspect(b)}")
        :error

      {:error, reason} ->
        Logger.warning("[EndPointBlank] Write to #{url_key} error: #{inspect(reason)}")
        :error
    end
  end
end
