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

  ## `cache_ttl` changes apply to entries already cached (sc-755)

  Every entry records both `written_at` and its own `expires_at` (the
  `cache_ttl` in force *when it was written*, added to `written_at`). On
  every read, `get/1` re-derives validity from the `cache_ttl` in force
  *right now* rather than trusting only the stamped `expires_at`: a hit
  requires both

    * `now < expires_at` — raising `cache_ttl` at runtime never extends an
      entry past what it was written with, and
    * `now - written_at < current cache_ttl` — lowering `cache_ttl` at
      runtime applies to it starting on the very next read, not just to
      entries written after the change.

  Both must hold; either one failing is a miss, and a miss on a stored
  key deletes that exact entry (`:ets.delete_object/2`, not `:ets.delete/2`)
  so a fresh write racing the read for the same key is never collateral
  damage.

  Deliberately not `expires_at - now <= current cache_ttl` (comparing
  *remaining* time against the new window): once enough real time has
  passed, an entry's remaining-until-original-expiry can coincidentally
  fall back under a new, shorter TTL window and look valid again even
  though it is older than that window allows. Anchoring both checks to the
  fixed `written_at` avoids that clamp trap.

  Cache key: `"epb_auth:{client_auth}:{path}:{method}:{app_name}"`
  Value stored: the `source_application_environment_id` from the 201 response.
  """

  use GenServer
  require Logger

  @app :end_point_blank_elixir
  @table :epb_auth_cache
  @max_size 1000
  @default_ttl_ms 300_000

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up *key* in the cache.

  Returns `{:hit, source_env_id}` only if the entry exists and is still
  valid against the `cache_ttl` in force *right now* — see the moduledoc
  for the two conditions that must both hold. `:miss` otherwise, which also
  deletes a found-but-stale entry (never a fresh one written concurrently
  under the same key — see the moduledoc). Always `:miss` while the cache
  is disabled (`cache_ttl <= 0`) — and, on that path, also clears the whole
  table so a later re-enable cannot resurrect what looked disabled. See
  `clear/0`.
  """
  def get(key) do
    current_ttl = ttl_ms()

    if current_ttl <= 0 do
      clear()
      :miss
    else
      now = now_ms()

      case :ets.lookup(@table, key) do
        [{^key, source_env_id, written_at, expires_at} = entry] ->
          if now < expires_at and now - written_at < current_ttl do
            {:hit, source_env_id}
          else
            :ets.delete_object(@table, entry)
            :miss
          end

        [] ->
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
        written_at = now_ms()
        expires_at = written_at + ttl
        GenServer.cast(__MODULE__, {:put, key, source_env_id, written_at, expires_at})
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
  def handle_cast({:put, key, source_env_id, written_at, expires_at}, state) do
    # put/2 decides whether to write based on the TTL in force when it is
    # called, then hands this GenServer an already-computed written_at /
    # expires_at pair. If the cache is disabled by the time this message is
    # handled, that stamp is stale: accepting it would let a write that
    # raced the disable land anyway and survive it, undoing the very
    # invalidation this cache exists to provide. Re-check the *current*
    # config here rather than trusting the caller's stamp.
    current_ttl = ttl_ms()

    if current_ttl <= 0 do
      {:noreply, state}
    else
      now = now_ms()

      # Evict entries stale under either rule get/1 enforces on read: past
      # their original (write-time) expiry, or older than the currently
      # configured cache_ttl measured from their own written_at. This is
      # best-effort housekeeping ahead of the size-cap pass below — get/1
      # is what actually guarantees a lowered cache_ttl is honored, on every
      # read, for anything this sweep does not immediately catch.
      :ets.select_delete(@table, [
        {{:_, :_, :"$1", :"$2"}, [{:orelse, {:<, :"$2", now}, {:>=, {:-, now, :"$1"}, current_ttl}}],
         [true]}
      ])

      # Enforce size cap: remove the entry expiring soonest
      if :ets.info(@table, :size) >= @max_size do
        oldest =
          :ets.foldl(
            fn {k, _, _written_at, exp}, acc ->
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

      :ets.insert(@table, {key, source_env_id, written_at, expires_at})
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

  # The cache's clock stays `System.monotonic_time/1` in every real
  # deployment: the offset below defaults to zero and is never set outside
  # tests. It exists only so tests can simulate the passage of time
  # deterministically (some of the windows this module's TTL logic has to
  # get right are minutes long) without sleeping the test process for real
  # or switching the cache to a different clock source. Reading it is a
  # lock-free application-env lookup, not a process round trip, so it does
  # not add a GenServer call to the read path in `get/1`.
  defp now_ms do
    System.monotonic_time(:millisecond) + Application.get_env(@app, :auth_cache_clock_offset_ms, 0)
  end
end
