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

    if ttl_ms() <= 0 do
      :miss
    else
      case :ets.lookup(@table, key) do
        [{^key, source_env_id, expires_at}] when expires_at > now ->
          {:hit, source_env_id}

        _ ->
          :miss
      end
    end
  end

  @doc "Stores a successful auth result (source_env_id may be nil) under *key*."
  def put(key, source_env_id) do
    case ttl_ms() do
      ttl when ttl <= 0 ->
        :ok

      ttl ->
        expires_at = System.monotonic_time(:millisecond) + ttl
        GenServer.cast(__MODULE__, {:put, key, source_env_id, expires_at})
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:put, key, source_env_id, expires_at}, state) do
    now = System.monotonic_time(:millisecond)

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

  # Narrowly `ArithmeticError`, which is what a nonsensical `cache_ttl` (nil, a
  # string, a float-shaped binary) raises on the multiplication. A bare `rescue
  # _` used to stand here and was harmless only by accident: the one other way
  # this line could fail was an `Agent.get/2` timeout, and a timeout is an exit,
  # which `rescue` never sees. sc-350 made that read raise instead, so a bare
  # rescue would now quietly swallow "the config store is down" and cache with a
  # made-up TTL — precisely the silent fallback sc-350 exists to remove.
  defp ttl_ms do
    EndPointBlank.Config.get().cache_ttl * 1_000
  rescue
    ArithmeticError -> @default_ttl_ms
  end
end
