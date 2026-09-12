defmodule EndPointBlank.AuthCache do
  @moduledoc """
  ETS-backed authorization result cache with TTL expiry and a size cap.

  Concurrent reads go directly to ETS (no GenServer round-trip).
  Mutations are serialized through the GenServer to make eviction safe.

  Setting `cache_ttl` to zero or less disables the cache outright: reads
  always miss, writes are refused (including one already queued when the
  config changed — see `handle_cast/2`), and every entry already stored is
  deleted, not merely hidden — see `clear/0`. That last part matters: an
  operator who disables the cache specifically to force-flush a revoked
  grant, then re-enables it, must not have that revoked grant's stale
  authorization resurface from cache. This mirrors the `clear()` primitive
  the JS, Python and Ruby SDKs already expose for the same purpose
  (`authentication-cache.js`, `authentication_cache.py`,
  `authentication_cache.rb`) — Elixir was the one SDK without it.

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
  or `:miss` otherwise. Always `:miss` while the cache is disabled
  (`cache_ttl <= 0`) — and, on that path, also clears the table so a later
  re-enable cannot resurrect what looked disabled. See `clear/0`.
  """
  def get(key) do
    if ttl_ms() <= 0 do
      clear()
      :miss
    else
      now = System.monotonic_time(:millisecond)

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
        clear()
        :ok

      ttl ->
        expires_at = System.monotonic_time(:millisecond) + ttl
        GenServer.cast(__MODULE__, {:put, key, source_env_id, expires_at})
    end
  end

  @doc """
  Deletes every entry from the cache, regardless of expiry.

  A single `:ets.delete_all_objects/1` on the `:public` table, safe to call
  from any process without going through the GenServer: unlike the size-cap
  eviction in `handle_cast/2` (a foldl-then-delete-then-insert sequence that
  needs serializing to stay consistent), wiping the whole table is one atomic
  operation with nothing to coordinate.

  Called automatically whenever the cache is disabled (`cache_ttl <= 0`) —
  see `get/1` and `put/2`. Also exposed publicly so a host application can
  force-flush the cache directly, matching the `clear()` the JS, Python and
  Ruby SDKs already provide for that purpose.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:put, key, source_env_id, expires_at}, state) do
    # put/2 decides whether to write based on the TTL in force when it is
    # called, then hands this GenServer an already-computed expires_at. If
    # the cache is disabled by the time this message is handled, that stamp
    # is stale: accepting it would let a write that raced the disable land
    # anyway and survive it, undoing the very invalidation this cache exists
    # to provide. Re-check the *current* config here rather than trusting the
    # caller's stamp.
    if ttl_ms() <= 0 do
      {:noreply, state}
    else
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
