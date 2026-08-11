defmodule EndPointBlank.AccessTokens do
  @moduledoc """
  In-memory holder for this node's access token.

  Intake issues a token against the application environment the authenticating
  credential belongs to. The hostname sent with a generation request only
  resolves the target server-side; it is not what the token is scoped to. A node
  authenticates as exactly one application environment, so it holds exactly one
  token, whatever hostnames its callers address it by.

  Tokens are proactively refreshed when they are within two minutes of expiry
  to avoid serving one that dies in flight — an expired token can never be
  revived, only replaced.
  """

  use GenServer

  @refresh_buffer_seconds 120
  @min_ttl_seconds 30

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Returns the held token, minting one if none is held or it is near expiry.

  `hostname` is sent with a generation request so intake can resolve the target
  application environment. It does not select which held token comes back —
  every caller shares one.
  """
  def token(hostname) do
    GenServer.call(__MODULE__, {:token, hostname})
  end

  @doc "Returns true if a token is held and is not about to expire."
  def exists? do
    GenServer.call(__MODULE__, :exists)
  end

  @doc """
  Discards the held token, but only if it is still the one the caller had.

  Every request in flight when a token is rejected reports the same stale
  value. Only the first of them should cause a mint — the rest are holding a
  token that has already been replaced, and clearing on their behalf would
  discard a good token and stampede intake.
  """
  def invalidate(stale_token) do
    GenServer.cast(__MODULE__, {:invalidate, stale_token})
  end

  @doc "Discards the held token."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # Callbacks

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:token, hostname}, _from, state) do
    {token, new_state} = fetch_or_generate(hostname, state)
    {:reply, token, new_state}
  end

  @impl true
  def handle_call(:exists, _from, state) do
    exists =
      case state do
        {_token, expires_at} -> usable?(expires_at)
        nil -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_cast({:invalidate, stale_token}, state) when is_binary(stale_token) do
    case state do
      {^stale_token, _expires_at} -> {:noreply, nil}
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:invalidate, _stale_token}, state), do: {:noreply, state}

  def handle_cast(:clear, _state), do: {:noreply, nil}

  # Helpers

  defp fetch_or_generate(hostname, state) do
    case state do
      {token, expires_at} when is_binary(token) ->
        if not_near_expiry?(expires_at),
          do: {token, state},
          else: generate_and_store(hostname, state)

      _ ->
        generate_and_store(hostname, state)
    end
  end

  defp generate_and_store(hostname, state) do
    case EndPointBlank.Commands.GenerateAccessToken.generate(hostname) do
      %{"token" => token, "expired_at" => expires_at_str} ->
        case DateTime.from_iso8601(expires_at_str) do
          {:ok, dt, _} -> {token, {token, dt}}
          _ -> {nil, state}
        end

      _ ->
        {nil, state}
    end
  end

  defp not_near_expiry?(expires_at) do
    buffer = DateTime.add(DateTime.utc_now(), @refresh_buffer_seconds, :second)
    DateTime.compare(expires_at, buffer) == :gt
  end

  defp usable?(expires_at) do
    min_ttl = DateTime.add(DateTime.utc_now(), @min_ttl_seconds, :second)
    DateTime.compare(expires_at, min_ttl) == :gt
  end
end
