defmodule EndPointBlank.AuthCache do
  @moduledoc """
  ETS-backed authorization result cache with TTL expiry and a size cap.

  Concurrent reads go directly to ETS (no GenServer round-trip).
  Mutations are serialized through the GenServer to make eviction safe.

  Cache key: `"epb_auth:{client_auth}:{path}:{method}:{app_name}"`
  Value stored: the `source_application_environment_id` from the 201 response.
  """

  use GenServer
  require Logger

  @table :epb_auth_cache
  @max_size 1000
  @default_ttl_ms 300_000

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up *key* in the cache.

  Returns `{:hit, source_env_id}` if the entry exists and has not expired,
  or `:miss` otherwise.
  """
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, source_env_id, expires_at}] when expires_at > now ->
        {:hit, source_env_id}

      _ ->
        :miss
    end
  end

  @doc "Stores a successful auth result (source_env_id may be nil) under *key*."
  def put(key, source_env_id) do
    GenServer.cast(__MODULE__, {:put, key, source_env_id})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:put, key, source_env_id}, state) do
    now = System.monotonic_time(:millisecond)
    expires_at = now + ttl_ms()

    # Evict expired entries
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    # Enforce size cap: remove the entry expiring soonest
    if :ets.info(@table, :size) >= @max_size do
      oldest =
        :ets.foldl(
          fn {k, _, exp}, acc ->
            case acc do
              nil -> {k, exp}
              {_, min_exp} when exp < min_exp -> {k, exp}
              acc -> acc
            end
          end,
          nil,
          @table
        )

      if oldest, do: :ets.delete(@table, elem(oldest, 0))
    end

    :ets.insert(@table, {key, source_env_id, expires_at})
    {:noreply, state}
  end

  defp ttl_ms do
    try do
      EndPointBlank.Config.get().cache_ttl * 1_000
    rescue
      _ -> @default_ttl_ms
    end
  end
end
