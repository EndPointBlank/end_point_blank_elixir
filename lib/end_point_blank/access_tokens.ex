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

  ## Why a mint failed

  `token/1` answers `nil` for every failure, because its callers fall back to
  Basic and have nothing else to do with the detail. But the detail matters:
  intake answers 401 for a credential it has rejected, and that is permanent
  until a human re-issues the credential, where a 5xx or a refused connection
  will likely be gone on the next call. `last_failure/1` reports the last one
  for a given URL, so a caller that wants to stop hammering intake -- or
  alarm -- can tell those apart. See `EndPointBlank.Commands.GenerateAccessToken`
  for the full taxonomy.
  """

  use GenServer

  require Logger

  alias EndPointBlank.Commands.GenerateAccessToken

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

  @typedoc """
  Why the last mint for a URL failed, or `nil` if the last one succeeded (or
  none has been attempted).

  `:credential_rejected` and `{:request_rejected, status}` are permanent --
  retrying changes nothing until the credential is re-issued or the
  environment is registered. `{:server_error, status}`,
  `{:transport_error, reason}` and `{:invalid_response, reason}` are transient.

  `{:invalid_response, reason}` is the one this module adds to
  `t:EndPointBlank.Commands.GenerateAccessToken.failure/0`: intake answered
  2xx, but with a body this cache cannot store -- no token, or a token with no
  `base_url` to key it under. A broken server, not a refused caller.
  """
  @type failure :: GenerateAccessToken.failure() | {:invalid_response, String.t()}

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

  Use `last_failure/1` to find out which kind of failure a `nil` was.
  """
  def token(base_url) do
    call({:token, base_url}, nil)
  end

  @doc "Returns true if a token covering `base_url` is held and not about to expire."
  def exists?(base_url) do
    call({:exists, base_url}, false)
  end

  @doc """
  Returns why the last mint attempted for `base_url` failed, or `nil` if the
  last one succeeded or none has been made.

  Pass the same URL you passed to `token/1`: the record is kept under the URL
  the caller asked about, not under the canonical base URL intake resolved it
  to, because on a failure there is no resolved base URL to key it under.

      case AccessTokens.token(url) do
        nil ->
          case AccessTokens.last_failure(url) do
            :credential_rejected -> alarm("re-issue the EndPointBlank credential")
            {:request_rejected, status} -> alarm("intake refused the request: \#{status}")
            _transient -> :ok
          end

        token ->
          {:ok, token}
      end

  See `t:failure/0` for the shapes and which of them are permanent. Answers
  `nil` -- never raises -- for a URL nothing was recorded under, including any
  argument that is not a binary.

  A successful mint clears the record for the URL it was asked about and for
  every URL the resolved base URL covers, so this cannot go on reporting a
  failure that has since been fixed.
  """
  @spec last_failure(term()) :: failure() | nil
  def last_failure(base_url) do
    call({:last_failure, base_url}, nil)
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

  @doc "Discards every held token, and every recorded failure."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # Callbacks

  @impl true
  def init(_), do: {:ok, empty_state()}

  @impl true
  def handle_call({:token, base_url}, _from, state) do
    {token, new_state} = fetch_or_generate(base_url, state)
    {:reply, token, new_state}
  end

  @impl true
  def handle_call({:exists, base_url}, _from, state) do
    exists =
      case match(base_url, state.tokens) do
        %{expires_at: expires_at} -> usable?(expires_at)
        nil -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_call({:last_failure, base_url}, _from, state) do
    # Map.get/2 with a non-binary key is simply a miss -- failures are only
    # ever recorded under binary keys -- so this needs no guard of its own to
    # keep a host application's stray argument from killing this process.
    {:reply, Map.get(state.failures, base_url), state}
  end

  @impl true
  def handle_cast({:invalidate, stale_token}, state) when is_binary(stale_token) do
    tokens = Map.reject(state.tokens, fn {_key, %{token: token}} -> token == stale_token end)
    {:noreply, %{state | tokens: tokens}}
  end

  def handle_cast({:invalidate, _stale_token}, state), do: {:noreply, state}

  def handle_cast(:clear, _state), do: {:noreply, empty_state()}

  # Helpers

  defp empty_state, do: %{tokens: %{}, failures: %{}}

  defp fetch_or_generate(base_url, state) do
    case match(base_url, state.tokens) do
      %{token: token, expires_at: expires_at} ->
        if not_near_expiry?(expires_at),
          do: {token, state},
          else: generate_and_store(base_url, state)

      nil ->
        generate_and_store(base_url, state)
    end
  end

  defp generate_and_store(base_url, state) do
    case safe_generate(base_url) do
      {:ok, payload} ->
        token = field(payload, "token")
        key = field(payload, "base_url")

        if usable_string?(token) and usable_string?(key) do
          store(base_url, key, token, payload, state)
        else
          # A 2xx that cannot be cached is a broken intake, and saying so is
          # not the same as saying the credential was refused. Keeping it a
          # distinct shape is the point of the whole story.
          fail(base_url, {:invalid_response, failure_reason(payload)}, state)
        end

      {:error, reason} ->
        fail(base_url, reason, state)
    end
  end

  defp store(base_url, key, token, payload, state) do
    entry = %{token: token, expires_at: parse_expiry(field(payload, "expired_at"))}

    # The entry just matched (if any) was found unusable and is what got
    # minted against. If intake resolved this call to a different
    # canonical base_url than the one that entry was stored under, that
    # old key must go -- otherwise it lingers, and being the longer of the
    # two it keeps winning the longest-match race forever, shadowing the
    # fresh entry and forcing a mint on every call. The failure branch
    # below already deletes on this same basis; this makes success agree.
    tokens =
      case match_key(base_url, state.tokens) do
        stale when stale != nil and stale != key -> Map.delete(state.tokens, stale)
        _ -> state.tokens
      end

    {token,
     %{
       state
       | tokens: Map.put(tokens, key, entry),
         failures: clear_failures(state.failures, base_url, key)
     }}
  end

  # A failed mint must not leave an expiring entry behind claiming to be
  # usable — callers would keep presenting it right up to the 401. Only the
  # entry that covers this URL goes: the longest match is the one just found
  # unusable, so a shorter, still-good entry for a different target survives.
  defp fail(base_url, reason, state) do
    tokens =
      case match_key(base_url, state.tokens) do
        nil -> state.tokens
        stale -> Map.delete(state.tokens, stale)
      end

    log_failure(base_url, reason)

    {nil, %{state | tokens: tokens, failures: record_failure(state.failures, base_url, reason)}}
  end

  # A 401 is not an outage. Logging it as one -- "Failed to generate access
  # token", which reads as intake being down -- is why nobody notices that a
  # credential has been revoked until traffic has been falling back to Basic
  # for a week. This line names the remedy instead.
  defp log_failure(base_url, :credential_rejected) do
    Logger.error(
      "[EndPointBlank] Access token credential was rejected for #{inspect(base_url)}: intake " <>
        "answered 401. This will NOT recover on its own — the API credential must be re-issued " <>
        "(check :client_id/:client_secret). Callers fall back to Basic until it is."
    )
  end

  defp log_failure(base_url, reason) do
    # inspect/1, not string interpolation: base_url is whatever a caller
    # passed to token/1 or exists?/1, and String.Chars has no
    # implementation for a map, tuple, PID, function, reference, port, or a
    # non-codepoint list. Interpolating it directly would raise
    # Protocol.UndefinedError right here, on the ordinary-miss path this
    # very branch exists to keep safe -- the crash would just move one line
    # rather than close. inspect/1 accepts any term.
    Logger.error(
      "[EndPointBlank] Failed to generate access token for #{inspect(base_url)}: #{describe(reason)}"
    )
  end

  defp describe({:request_rejected, status}), do: "intake rejected the request: status=#{status}"
  defp describe({:server_error, status}), do: "intake failed: status=#{status}"
  defp describe({:transport_error, reason}), do: "could not reach intake: #{inspect(reason)}"
  defp describe({:invalid_response, reason}), do: reason

  # Failures are keyed by the URL the caller asked about, because a failed
  # mint has no resolved base URL to key on. That set is unbounded in
  # principle -- a caller passing a different resource URL every time would
  # grow it -- so it is bounded from the other end instead: any success under
  # a covering base URL drops every record it covers (see clear_failures/3),
  # and clear/0 drops the lot. Only a binary is recorded; a stray non-binary
  # argument logs loudly but is not worth a permanent map entry.
  defp record_failure(failures, base_url, reason) when is_binary(base_url) and base_url != "" do
    Map.put(failures, base_url, reason)
  end

  defp record_failure(failures, _base_url, _reason), do: failures

  # A success says every failure it covers is stale: the exact URL that was
  # asked about, and anything under the base URL intake resolved it to.
  # Leaving them would let last_failure/1 go on reporting a rejected
  # credential that has since been re-issued.
  defp clear_failures(failures, base_url, key) do
    failures
    |> Enum.reject(fn {url, _reason} ->
      url == base_url or url == key or String.starts_with?(url, key <> "/")
    end)
    |> Map.new()
  end

  # Only a map can be a token document. A 2xx whose decoded body is a list, a
  # string or a number would otherwise reach `body["token"]`, and Access
  # raises for those -- inside this GenServer, outside safe_generate/1's
  # rescue. An SDK must not be able to crash the application it is embedded in
  # because intake is misconfigured.
  defp field(payload, key) when is_map(payload), do: Map.get(payload, key)
  defp field(_payload, _key), do: nil

  defp usable_string?(value), do: is_binary(value) and value != ""

  defp failure_reason(%{"error" => error}) when is_binary(error), do: error

  # intake is expected to send "error" as a string. A misbehaving intake
  # sending anything else (a nested object, a number) must not crash this
  # GenServer either -- inspect/1, not the plain string interpolation this
  # value flows into at the call site, for the same reason base_url got the
  # same treatment above: "An SDK must not be able to crash the application
  # it is embedded in because intake is misconfigured."
  defp failure_reason(%{"error" => error}), do: inspect(error)

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
  # back to Basic. There is no retry catching a token that dies sooner than the
  # guess -- invalidate/1 has no caller on this path -- so a bad guess means
  # 401s until the cache's own expiry-based refresh catches up.
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
  # turns a refusal or a transport error into an `{:error, reason}`; this is
  # for what it cannot anticipate, such as a malformed access-token URL built
  # from bad config. An SDK must not be able to crash the application it is
  # embedded in because intake is misconfigured.
  #
  # It maps to a transport error, never to `:credential_rejected`: a raise
  # says nothing whatever about the credential, and calling it permanent
  # would tell every caller to stop retrying a bug in this SDK.
  defp safe_generate(base_url) do
    GenerateAccessToken.generate_result(base_url)
  rescue
    error ->
      Logger.error("[EndPointBlank] Minting an access token raised: #{Exception.message(error)}")
      {:error, {:transport_error, error}}
  catch
    kind, reason ->
      Logger.error("[EndPointBlank] Minting an access token #{kind}: #{inspect(reason)}")
      {:error, {:transport_error, {kind, reason}}}
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
  #
  # Anything that is not a usable binary short-circuits to "no match" instead
  # of falling into the comparison below -- not just nil and "". With a cold
  # cache (nothing to iterate) that comparison never runs and a bad value
  # quietly proceeds to a mint; with a warm cache it runs
  # `String.starts_with?(base_url, ...)`, which requires both arguments to be
  # binaries and raises `FunctionClauseError` for anything else -- an
  # integer, atom, boolean, list, map, tuple, not just nil -- killing this
  # GenServer by the identical mechanism. `token/1` and `exists?/1` are
  # public API; a host application can pass anything. Guarding here -- the
  # one matcher both reach through `fetch_or_generate/2` and `match/2` --
  # makes cold and warm agree on the same ordinary-miss outcome for every
  # non-binary shape, instead of one of them raising.
  defp match_key(base_url, _entries) when not is_binary(base_url) or base_url == "", do: nil

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
