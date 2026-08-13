defmodule EndPointBlank.AccessTokens do
  @moduledoc """
  In-process cache of this node's access tokens, one per application
  environment.

  A token is cached under the canonical base URL intake resolved the request
  to -- not under the URL the caller supplied. A caller asks for the URL it is
  about to call; intake answers with the base URL of the environment that URL
  belongs to, and subsequent calls anywhere under that base URL reuse the
  entry. A node that calls several targets therefore holds several tokens.

  Lookup is a plain exact-or-path-prefix comparison, with the longest match
  winning. The SDK deliberately does not normalize: intake owns that rule, and
  a miss costs one extra request rather than a wrong answer.

  All reads and writes go through this GenServer's mailbox, so they are fully
  serialized -- unlike the Python and Ruby ports, there is no lock-free fast
  path here for a concurrent write to race, so this holds a plain map and
  mutates it directly. Do not add copy-on-write; there is nothing here for it
  to protect.

  Tokens are proactively refreshed when they are within two minutes of expiry
  to avoid serving one that dies in flight -- an expired token can never be
  revived, only replaced.
  """

  use GenServer

  require Logger

  @refresh_buffer_seconds 120
  @min_ttl_seconds 30

  # How long to hold a token whose expiry intake sent unreadably.
  @default_lifetime_seconds 3600

  # Minting happens inside the GenServer, so a caller waits out the HTTP round
  # trip. `Http.post/3` allows three attempts of up to five seconds each with
  # 200 ms between them, so a mint against a hung intake can run for about
  # 15.4 s — three times the 5 s a `GenServer.call/2` allows by default. Left at
  # the default, a slow intake would time out every caller and take down the
  # host application's request process while the mint was still in flight.
  @call_timeout_ms 20_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Returns a valid access token for `base_url`, minting one if no usable entry
  covers it.

  `base_url` is the URL you are about to call, with any query string and
  fragment removed. It is sent verbatim; intake normalizes it and matches it
  against registered base URLs by longest path prefix.

  Returns `nil` rather than raising if a token cannot be produced -- which
  includes a response that carried a token but no `base_url` (nothing to
  cache it under) as well as the cache failing to answer in time -- so an
  intake outage costs the caller a fall back to Basic rather than its request.
  """
  def token(base_url) do
    call({:token, base_url}, nil)
  end

  @doc "Returns true if a token covering `base_url` is held and not about to expire."
  def exists?(base_url) do
    call({:exists, base_url}, false)
  end

  defp call(message, on_failure) do
    GenServer.call(__MODULE__, message, @call_timeout_ms)
  catch
    :exit, _reason -> on_failure
  end

  @doc """
  Discards a held token, but only if it is still the one the caller had.

  Every request in flight when a token is rejected reports the same stale
  value. Only the first of them should cause a mint — the rest are holding a
  token that has already been replaced, and clearing on their behalf would
  discard a good token and stampede intake.

  The lookup is by token value because a rejected caller has a token, not a
  base_url.
  """
  def invalidate(stale_token) do
    GenServer.cast(__MODULE__, {:invalidate, stale_token})
  end

  @doc "Discards every held token."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # Callbacks

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:token, base_url}, _from, state) do
    {token, new_state} = fetch_or_generate(base_url, state)
    {:reply, token, new_state}
  end

  @impl true
  def handle_call({:exists, base_url}, _from, state) do
    exists =
      case match(base_url, state) do
        %{expires_at: expires_at} -> usable?(expires_at)
        nil -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_cast({:invalidate, stale_token}, state) when is_binary(stale_token) do
    new_state = Map.reject(state, fn {_key, %{token: token}} -> token == stale_token end)
    {:noreply, new_state}
  end

  def handle_cast({:invalidate, _stale_token}, state), do: {:noreply, state}

  def handle_cast(:clear, _state), do: {:noreply, %{}}

  # Helpers

  defp fetch_or_generate(base_url, state) do
    case match(base_url, state) do
      %{token: token, expires_at: expires_at} ->
        if not_near_expiry?(expires_at),
          do: {token, state},
          else: generate_and_store(base_url, state)

      nil ->
        generate_and_store(base_url, state)
    end
  end

  # A failed mint must not leave an expiring entry behind claiming to be
  # usable — callers would keep presenting it right up to the 401. Only the
  # entry that covers this URL goes: the longest match is the one just found
  # unusable, so a shorter, still-good entry for a different target survives.
  defp generate_and_store(base_url, state) do
    payload = safe_generate(base_url)
    token = payload && payload["token"]
    key = payload && payload["base_url"]

    if is_binary(token) and token != "" and is_binary(key) and key != "" do
      entry = %{token: token, expires_at: parse_expiry(payload["expired_at"])}
      {token, Map.put(state, key, entry)}
    else
      new_state =
        case match_key(base_url, state) do
          nil -> state
          stale -> Map.delete(state, stale)
        end

      Logger.error(
        "[EndPointBlank] Failed to generate access token for #{base_url}: #{failure_reason(payload)}"
      )

      {nil, new_state}
    end
  end

  defp failure_reason(nil), do: "no response"
  defp failure_reason(%{"error" => error}), do: error

  defp failure_reason(%{"token" => token}) when is_binary(token) and token != "" do
    # Distinct from a rejected request: intake's base_url is NOT NULL, and it
    # answers 422 rather than minting when the caller's URL resolves to no
    # environment. A 201 without one is a broken server.
    "response carried a token but no base_url"
  end

  defp failure_reason(_payload), do: "no token in response"

  # An unreadable or absent expiry keeps the token for a default hour, which is
  # what the other four SDKs do. A guess, but a working one: treating the token
  # as unusable instead means a mint on every inbound request for as long as the
  # intake misbehaves, and with nothing held every one of those requests falls
  # back to Basic. If the token really does die sooner, the 401 retry
  # invalidates it and mints another.
  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> default_expiry()
    end
  end

  defp parse_expiry(_value), do: default_expiry()

  defp default_expiry, do: DateTime.add(DateTime.utc_now(), @default_lifetime_seconds, :second)

  # Minting runs inside this GenServer, so anything it raises would kill the
  # process — and enough restarts take the SDK's whole supervision tree, and
  # with it the host application's, down with it. `GenerateAccessToken` already
  # turns a refusal or a transport error into `nil`; this is for what it cannot
  # anticipate, such as a malformed access-token URL built from bad config.
  # An SDK must not be able to crash the application it is embedded in because
  # intake is misconfigured.
  defp safe_generate(base_url) do
    EndPointBlank.Commands.GenerateAccessToken.generate(base_url)
  rescue
    error ->
      Logger.error("[EndPointBlank] Minting an access token raised: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.error("[EndPointBlank] Minting an access token #{kind}: #{inspect(reason)}")
      nil
  end

  defp not_near_expiry?(expires_at) do
    buffer = DateTime.add(DateTime.utc_now(), @refresh_buffer_seconds, :second)
    DateTime.compare(expires_at, buffer) == :gt
  end

  defp usable?(expires_at) do
    min_ttl = DateTime.add(DateTime.utc_now(), @min_ttl_seconds, :second)
    DateTime.compare(expires_at, min_ttl) == :gt
  end

  # Returns the longest key in `entries` covering `base_url`, or `nil`.
  #
  # Deliberately not a port of intake's matcher: no normalization on either
  # side. A caller that passes a non-canonical URL simply misses and mints
  # again, which costs one HTTP call and is never a wrong answer.
  defp match_key(base_url, entries) do
    entries
    |> Map.keys()
    |> Enum.filter(&(base_url == &1 or String.starts_with?(base_url, &1 <> "/")))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp match(base_url, entries) do
    case match_key(base_url, entries) do
      nil -> nil
      key -> Map.get(entries, key)
    end
  end
end
