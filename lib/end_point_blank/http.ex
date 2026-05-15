defmodule EndPointBlank.Http do
  @moduledoc "Shared HTTP helper with retry logic for all EndPointBlank API calls."

  require Logger

  @max_attempts 3
  @retry_delay_ms 200

  @doc """
  POSTs `body` as JSON to `url` with the given `auth_header`.
  Retries up to 3 times with a 500 ms delay between attempts on network error.
  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def post(url, body, auth_header) do
    do_post(url, body, auth_header, 1)
  end

  defp do_post(url, body, auth_header, attempt) do
    case Req.post(url, json: body, headers: [{"authorization", auth_header}]) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} ->
        Logger.warning("[EndPointBlank] HTTP POST to #{url} failed (attempt #{attempt}/#{@max_attempts}): #{inspect(reason)}")

        if attempt < @max_attempts do
          Process.sleep(@retry_delay_ms)
          do_post(url, body, auth_header, attempt + 1)
        else
          {:error, reason}
        end
    end
  end
end
