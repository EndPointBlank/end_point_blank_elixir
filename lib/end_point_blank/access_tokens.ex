defmodule EndPointBlank.AccessTokens do
  @moduledoc """
  Thread-safe in-memory cache for access tokens keyed by target hostname.

  Tokens are proactively refreshed when they are within two minutes of expiry
  to avoid serving stale tokens under concurrent load.
  """

  use GenServer

  @refresh_buffer_seconds 120

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns the cached token for `hostname`, generating a new one if needed."
  def token(hostname) do
    GenServer.call(__MODULE__, {:token, hostname})
  end

  @doc "Returns true if a non-expiring token is cached for `hostname`."
  def exists?(hostname) do
    GenServer.call(__MODULE__, {:exists, hostname})
  end

  @doc "Removes the cached token for `hostname`."
  def remove(hostname) do
    GenServer.cast(__MODULE__, {:remove, hostname})
  end

  @doc "Clears all cached tokens."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # Callbacks

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:token, hostname}, _from, state) do
    {token, new_state} = fetch_or_generate(hostname, state)
    {:reply, token, new_state}
  end

  @impl true
  def handle_call({:exists, hostname}, _from, state) do
    exists =
      case Map.get(state, hostname) do
        {_token, expires_at} -> not_near_expiry?(expires_at)
        nil -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_cast({:remove, hostname}, state), do: {:noreply, Map.delete(state, hostname)}

  @impl true
  def handle_cast(:clear, _state), do: {:noreply, %{}}

  # Helpers

  defp fetch_or_generate(hostname, state) do
    case Map.get(state, hostname) do
      {token, expires_at} when not is_nil(token) ->
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
          {:ok, dt, _} -> {token, Map.put(state, hostname, {token, dt})}
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
end
