defmodule EndPointBlank.Http do
  @moduledoc "Shared HTTP helper with retry logic for all EndPointBlank API calls."

  require Logger

  @max_attempts 3
  @retry_delay_ms 200

  # Bounds on how long a single attempt may block, so a slow/hung intake
  # can never hold the caller (or the DelayedWriter's GenServer mailbox)
  # open indefinitely. Each retry re-applies these bounds.
  @receive_timeout_ms 5_000
  @connect_timeout_ms 3_000

  @doc """
  POSTs `body` as JSON to `url` with the given `auth_header`.
  Retries up to 3 times with a 200 ms delay between attempts on network error.
  Each attempt is bounded by a connect timeout and a receive timeout so a
  hung intake can never block the caller indefinitely.
  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def post(url, body, auth_header) do
    do_post(url, body, auth_header, 1)
  end

  @doc false
  # Req options applied to every attempt. Extracted so the bounded timeouts
  # can be asserted directly in tests without needing to observe them
  # server-side (receive_timeout/connect_options are client-side transport
  # settings and never appear on the wire).
  def req_options do
    [
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    ]
  end

  @doc """
  The `x-epb-sdk` value sent on every call to intake: `elixir/<version>`, the
  version of this library as loaded (sc-1463). intake ignores it today; it is
  there so intake can record the oldest version seen per credential, and so
  tell whether every SDK using a credential is new enough to follow its
  organization to another intake.
  """
  def sdk_header do
    "elixir/" <> sdk_version()
  end

  # Read from the loaded application spec rather than baked in at compile
  # time, so it is the version actually running. "unknown" only if the
  # application is not loaded, which no call path here allows in practice.
  defp sdk_version do
    case Application.spec(:end_point_blank_elixir, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  defp do_post(url, body, auth_header, attempt) do
    opts =
      [json: body, headers: [{"authorization", auth_header}, {"x-epb-sdk", sdk_header()}]] ++
        req_options() ++ test_plug_opts()

    case Req.post(url, opts) do
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

  # Test-only seam: lets tests stub the transport via Req.Test without
  # touching the public post/3 contract. No-op unless explicitly configured.
  defp test_plug_opts do
    case Application.get_env(:end_point_blank_elixir, :req_test_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
