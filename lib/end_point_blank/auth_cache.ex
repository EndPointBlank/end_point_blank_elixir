defmodule EndPointBlank.AuthCache do
  @moduledoc """
  ETS-backed authorization result cache with TTL expiry and a size cap.

  Concurrent reads go directly to ETS (no GenServer round-trip).
  Mutations are serialized through the GenServer to make eviction safe.

  Setting `cache_ttl` to zero or less disables the cache: reads always
  miss, writes are refused (including one already queued when the config
  changed — see `handle_cast/2`), and **both** `get/1` and `put/2` clear
  the *whole* table — every entry, not just the one being looked up or
  written — the moment either of them observes the disabled state. Clearing
  the whole table, not just one key, matters: an operator disabling the
  cache specifically to force-flush one revoked grant, then re-enabling it,
  must not have any *other* entry already cached — one that request never
  touched — resurface once `cache_ttl` is restored. This mirrors the
  `clear()` primitive the JS, Python, Ruby and Java SDKs of this same
  contract expose for the same purpose (`authentication-cache.js`,
  `authentication_cache.py`, `authentication_cache.rb`,
  `AuthenticationCache.java`).

  **Residual, deliberately not fixed here (the same in all five SDKs of
  this contract):** the clear only runs when `get/1` or `put/2` is actually
  *called* while `cache_ttl <= 0` — never at `configure/1` time itself, and
  never merely because a request came in. In this library the only caller
  of either function is `EndPointBlank.Commands.EndpointAuthorize`
  (reached through `EndPointBlank.Plug.Authorized`), so it is specifically
  an **authorize call** — or a direct call to `get/1`/`put/2` — made while
  disabled that triggers the flush. A host that only ever calls
  `EndPointBlank.Authorization.basic_header/0` or otherwise authenticates
  without going through the authorize plug never reaches `AuthCache` at
  all, disabled or not, and toggling `cache_ttl` around such a call flushes
  nothing. Likewise, `EndPointBlank.configure(cache_ttl: 0)` immediately
  followed by `EndPointBlank.configure(cache_ttl: 300)`, with no authorize
  call (or direct `get/1`/`put/2`) in between, flushes nothing. Call
  `clear/0` directly when the flush itself is the goal and an authorize
  call in between is not guaranteed.

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

  A row left behind by a pre-sc-755 release (<= 0.7.0, three elements:
  `{key, source_env_id, expires_at}`, no `written_at`) can still be
  resident after a hot code upgrade that does not drop the ETS table.
  `get/1` treats such a row as a miss and deletes it rather than raising.

  Cache key: `"epb_auth:{client_auth}:{path}:{method}:{app_name}"`
  Value stored: the `source_application_environment_id` from the 201 response.

  `get/2` and `put/3` accept an explicit `now` (the same monotonic
  millisecond clock `get/1`/`put/2` pass by default) and are `@doc false`:
  they exist only so tests can exercise specific points in time
  deterministically, without sleeping for real or giving any
  configuration-reachable surface control over this cache's clock.
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

  Returns `{:hit, source_env_id}` only if the entry exists and is still
  valid against the `cache_ttl` in force *right now* — see the moduledoc
  for the two conditions that must both hold. `:miss` otherwise, which also
  deletes a found-but-stale entry (never a fresh one written concurrently
  under the same key — see the moduledoc). Always `:miss` while the cache
  is disabled (`cache_ttl <= 0`) — and, on that path, also clears the whole
  table so a later re-enable cannot resurrect what looked disabled. See
  `clear/0`.
  """
  def get(key), do: get(key, System.monotonic_time(:millisecond))

  @doc false
  def get(key, now) do
    current_ttl = ttl_ms()

    if current_ttl <= 0 do
      clear()
      :miss
    else
      case :ets.lookup(@table, key) do
        [{^key, source_env_id, written_at, expires_at} = entry] ->
          if now < expires_at and now - written_at < current_ttl do
            {:hit, source_env_id}
          else
            :ets.delete_object(@table, entry)
            :miss
          end

        [{^key, _source_env_id, _expires_at} = legacy_entry] ->
          # A row written by a pre-sc-755 (<= 0.7.0) release: a 3-tuple
          # with no written_at. The ETS table survives a hot code upgrade
          # (only a process restart drops it), and the 4-tuple clause
          # above can never match it, so left alone it would raise a
          # CaseClauseError out of every future get/1 for this key and
          # sit in the table forever — nothing else here inspects a row's
          # shape closely enough to clean it up. Treat it like any other
          # stale entry instead: miss, and delete it.
          :ets.delete_object(@table, legacy_entry)
          :miss

        [] ->
          :miss
      end
    end
  end

  @doc "Stores a successful auth result (source_env_id may be nil) under *key*."
  def put(key, source_env_id), do: put(key, source_env_id, System.monotonic_time(:millisecond))

  @doc false
  def put(key, source_env_id, now) do
    case ttl_ms() do
      ttl when ttl <= 0 ->
        clear()
        :ok

      ttl ->
        expires_at = now + ttl
        GenServer.cast(__MODULE__, {:put, key, source_env_id, now, expires_at})
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
      now = System.monotonic_time(:millisecond)

      # Evict entries stale under either rule get/1 enforces on read: past
      # their original (write-time) expiry, or older than the currently
      # configured cache_ttl measured from their own written_at. This is
      # best-effort housekeeping ahead of the size-cap pass below — get/1
      # is what actually guarantees a lowered cache_ttl is honored, on every
      # read, for anything this sweep does not immediately catch. A legacy
      # (pre-sc-755) 3-tuple row simply does not match this 4-tuple pattern
      # and is left alone here; get/1 is what cleans those up (see its doc).
      :ets.select_delete(@table, [
        {{:_, :_, :"$1", :"$2"},
         [{:orelse, {:<, :"$2", now}, {:>=, {:-, now, :"$1"}, current_ttl}}], [true]}
      ])

      # Enforce size cap: remove the entry expiring soonest. Uses elem/2
      # rather than a tuple pattern so a legacy 3-tuple row left in the
      # table by a hot upgrade (see get/1's moduledoc) cannot blow up this
      # foldl with a FunctionClauseError -- key is always the 1st element
      # and expires_at always the last, in both the 3- and 4-tuple shapes.
      if :ets.info(@table, :size) >= @max_size do
        oldest =
          :ets.foldl(
            fn tuple, acc ->
              k = elem(tuple, 0)
              exp = elem(tuple, tuple_size(tuple) - 1)

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
end
