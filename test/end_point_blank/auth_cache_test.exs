defmodule EndPointBlank.AuthCacheTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{AuthCache, Config}

  @max_size 1_000

  setup do
    on_exit(&Config.reset/0)

    # The table is process-wide and shared for the life of the run, including
    # by other test files that exercise AuthCache (e.g. EndpointAuthorizeTest).
    # Calling the now-public clear/0 here would be one more moving part to
    # keep synchronized with every other suite touching the same table, so
    # every test here just works on a key nothing else will collide with.
    %{key: "epb_auth:test:#{System.unique_integer([:positive])}"}
  end

  # put/2 is a cast; syncing on the GenServer guarantees it has landed.
  defp sync, do: :sys.get_state(AuthCache)

  defp put(key, value) do
    AuthCache.put(key, value)
    sync()
  end

  # Stores under an explicit `now` instead of the real clock, via put/3 --
  # `@doc false`, and only ever called from tests -- so a test can simulate
  # writing at one point in time and reading at another, arbitrarily far
  # apart (some of the windows below are minutes long), without sleeping
  # the test process for real or giving anything reachable from production
  # config control over this cache's clock. See the moduledoc.
  defp put_at(key, value, now) do
    AuthCache.put(key, value, now)
    sync()
  end

  describe "get/1" do
    test "is a miss for a key that was never stored", %{key: key} do
      assert AuthCache.get(key) == :miss
    end

    test "returns what was stored", %{key: key} do
      put(key, {"app-env-1", nil})

      assert AuthCache.get(key) == {:hit, {"app-env-1", nil}}
    end

    test "treats a stored nil as a real entry, not an absent one", %{key: key} do
      # Intake can authorize without naming an environment. If that were read as
      # a miss, every such request would go back over the network.
      put(key, {nil, nil})

      assert AuthCache.get(key) == {:hit, {nil, nil}}
    end

    test "distinguishes keys that differ by a single character", %{key: key} do
      put(key, {"app-env-1", nil})

      assert AuthCache.get(key <> "x") == :miss
    end
  end

  describe "expiry" do
    test "an entry stored with a zero TTL is never served", %{key: key} do
      Config.update(cache_ttl: 0)
      put(key, {"app-env-1", nil})

      assert AuthCache.get(key) == :miss
    end

    test "an entry stored with a live TTL is served", %{key: key} do
      Config.update(cache_ttl: 300)
      put(key, {"app-env-1", nil})

      assert AuthCache.get(key) == {:hit, {"app-env-1", nil}}
    end

    test "a later write replaces the value under the same key", %{key: key} do
      put(key, {"app-env-1", nil})
      put(key, {"app-env-2", nil})

      assert AuthCache.get(key) == {:hit, {"app-env-2", nil}}
    end

    test "lowering the TTL to zero invalidates an existing entry", %{key: key} do
      Config.update(cache_ttl: 300)
      put(key, {"app-env-1", nil})

      Config.update(cache_ttl: 0)

      assert AuthCache.get(key) == :miss
    end

    test "disabling the cache deletes existing entries, so re-enabling cannot resurrect them",
         %{key: key} do
      Config.update(cache_ttl: 300)
      put(key, {"app-env-1", nil})

      Config.update(cache_ttl: 0)
      assert AuthCache.get(key) == :miss

      # The entry must be gone, not merely hidden by the ttl_ms() <= 0 guard on
      # get/1 — check the table directly rather than through the cache's own
      # read path, which would report :miss either way and could not tell
      # "deleted" from "masked".
      assert :ets.lookup(:epb_auth_cache, key) == []

      # Restoring the old TTL must not bring the entry back. An operator who
      # disables the cache specifically to force-flush a revoked grant, then
      # re-enables it, must not have that revoked grant's stale authorization
      # resurface from cache.
      Config.update(cache_ttl: 300)

      assert AuthCache.get(key) == :miss
    end

    test "a write already in flight when the cache is disabled is not stored", %{key: key} do
      Config.update(cache_ttl: 3_600)

      :sys.suspend(AuthCache)

      try do
        # Decided (and cast) while the TTL was still live...
        assert AuthCache.put(key, {"app-env-1", nil}) == :ok
        # ...but the cache is disabled before the GenServer gets to handle it.
        Config.update(cache_ttl: 0)
      after
        :sys.resume(AuthCache)
      end

      sync()

      # handle_cast/2 must re-check the *current* config rather than trusting
      # the expires_at it was handed: accepting this write would let a decision
      # made before the disable survive the very disable it raced, undoing the
      # invalidation this cache exists to provide.
      assert :ets.lookup(:epb_auth_cache, key) == []
      assert AuthCache.get(key) == :miss

      Config.update(cache_ttl: 3_600)
      assert AuthCache.get(key) == :miss
    end
  end

  describe "runtime cache_ttl changes apply to already-cached entries (sc-755)" do
    test "(a) lowering the TTL invalidates an entry once it is older than the new window",
         %{key: key} do
      t0 = System.monotonic_time(:millisecond)
      Config.update(cache_ttl: 300)
      put_at(key, {"app-env-1", nil}, t0)

      Config.update(cache_ttl: 10)

      assert AuthCache.get(key, t0 + 11_000) == :miss

      # A miss on a stored key must actually remove it (:ets.delete_object/2),
      # not just report :miss while leaving the row behind -- checking the
      # table directly is the only way to tell "deleted" from "reported
      # stale but still sitting there".
      assert :ets.lookup(:epb_auth_cache, key) == []
    end

    test "(b) clamp bug: falling remaining-time-to-original-expiry must not look valid again",
         %{key: key} do
      t0 = System.monotonic_time(:millisecond)
      Config.update(cache_ttl: 300)
      put_at(key, {"app-env-1", nil}, t0)

      Config.update(cache_ttl: 10)

      # 295s in: only 5s remain until the *original* 300s expiry, comfortably
      # inside a naive "expires_at - now <= current_ttl (10s)" clamp, which
      # would misread this as freshly valid. It is actually 295s old against
      # a 10s window and must miss -- this is the exact bug the story names.
      assert AuthCache.get(key, t0 + 295_000) == :miss
    end

    test "(c) raising the TTL never resurrects an entry that is already stale under it",
         %{key: key} do
      t0 = System.monotonic_time(:millisecond)
      Config.update(cache_ttl: 10)
      put_at(key, {"app-env-1", nil}, t0)

      Config.update(cache_ttl: 300)

      assert AuthCache.get(key, t0 + 11_000) == :miss
    end

    test "(d) disabling clears the entry, and restoring the old TTL does not resurrect it",
         %{key: key} do
      Config.update(cache_ttl: 300)
      put(key, {"app-env-1", nil})

      Config.update(cache_ttl: 0)
      assert AuthCache.get(key) == :miss
      assert :ets.lookup(:epb_auth_cache, key) == []

      Config.update(cache_ttl: 300)
      assert AuthCache.get(key) == :miss
    end

    test "(d2) a disabled READ clears every entry, not only the key looked up", %{key: key_a} do
      key_b = key_a <> ":b"
      Config.update(cache_ttl: 300)
      put(key_a, {"app-env-a", nil})
      put(key_b, {"app-env-b", nil})

      Config.update(cache_ttl: 0)
      # Only key_a is ever looked up while disabled...
      assert AuthCache.get(key_a) == :miss

      # ...but the whole table must be gone, not just key_a: a per-key
      # delete on this branch would leave key_b sitting in the table,
      # answering again the moment cache_ttl is restored below.
      assert :ets.info(:epb_auth_cache, :size) == 0

      Config.update(cache_ttl: 300)
      assert AuthCache.get(key_b) == :miss
    end

    test "(d2) a disabled STORE clears every entry, not only the key being stored",
         %{key: key_a} do
      key_b = key_a <> ":b"
      key_c = key_a <> ":c"
      Config.update(cache_ttl: 300)
      put(key_a, {"app-env-a", nil})
      put(key_b, {"app-env-b", nil})

      Config.update(cache_ttl: 0)
      # key_c was never cached, so a per-key delete on this branch would
      # delete nothing and leave key_a and key_b both sitting in the table.
      put(key_c, {"app-env-c", nil})

      assert :ets.info(:epb_auth_cache, :size) == 0

      Config.update(cache_ttl: 300)
      assert AuthCache.get(key_a) == :miss
      assert AuthCache.get(key_b) == :miss
    end

    test "(d2) a disabled read of a key that was never cached still clears every OTHER entry",
         %{key: key_a} do
      never_cached_key = key_a <> ":never-cached"
      Config.update(cache_ttl: 300)
      put(key_a, {"app-env-a", nil})

      Config.update(cache_ttl: 0)
      # The looked-up key isn't even in the table -- a naive "delete the
      # key I was asked about" implementation deletes nothing here, and
      # key_a (never looked up) would incorrectly survive.
      assert AuthCache.get(never_cached_key) == :miss
      assert :ets.info(:epb_auth_cache, :size) == 0
    end

    test "(e) sanity: an unchanged TTL within the window is still a hit", %{key: key} do
      Config.update(cache_ttl: 300)
      put(key, {"app-env-1", nil})

      assert AuthCache.get(key) == {:hit, {"app-env-1", nil}}
    end

    test "a row left by a pre-sc-755 release (0.7.0 and earlier, a 3-tuple with no written_at) " <>
           "is a miss and is removed, not raised on",
         %{key: key} do
      Config.update(cache_ttl: 300)
      legacy_expires_at = System.monotonic_time(:millisecond) + 300_000
      # 0.7.0's row shape: {key, source_env_id, expires_at}. The table
      # survives a hot code upgrade (only a process restart drops it), so
      # this is what an old row looks like after upgrading to this version
      # without restarting.
      :ets.insert(:epb_auth_cache, {key, {"app-env-1", nil}, legacy_expires_at})

      assert AuthCache.get(key) == :miss
      assert :ets.lookup(:epb_auth_cache, key) == []
    end

    test "a legacy 3-tuple row does not crash the size-cap eviction sweep", %{key: key} do
      Config.update(cache_ttl: 300)
      now = System.monotonic_time(:millisecond)

      filler_keys = for i <- 1..(@max_size - 1), do: "#{key}:#{i}"
      legacy_key = "#{key}:legacy"

      # This table is shared for the life of the whole test run (see the
      # setup comment above), so bulk-filling it directly like this must
      # clean up after itself -- an on_exit runs even if an assertion below
      # fails, unlike inline cleanup at the end of the test body.
      on_exit(fn ->
        Enum.each(filler_keys, &:ets.delete(:epb_auth_cache, &1))
        :ets.delete(:epb_auth_cache, legacy_key)
        :ets.delete(:epb_auth_cache, key)
      end)

      # Fill directly via ETS (bypassing the GenServer -- the table is
      # :public) so the very next handle_cast's size-cap branch runs its
      # foldl over a table that already includes one pre-sc-755 (3-tuple)
      # row alongside normal 4-tuple ones.
      for k <- filler_keys,
          do: :ets.insert(:epb_auth_cache, {k, {"app-env-1", nil}, now, now + 300_000})

      :ets.insert(:epb_auth_cache, {legacy_key, {"app-env-1", nil}, now + 300_000})

      put(key, {"app-env-2", nil})

      assert Process.alive?(Process.whereis(AuthCache))
    end
  end

  describe "resilience" do
    test "a nonsensical cache_ttl falls back to the default instead of killing the cache", %{
      key: key
    } do
      # The cache sits in front of every authorization; a bad config value taking
      # it down would take authorization down with it.
      Config.update(cache_ttl: nil)

      put(key, {"app-env-1", nil})

      assert AuthCache.get(key) == {:hit, {"app-env-1", nil}}
      assert Process.alive?(Process.whereis(AuthCache))
    end

    test "does not queue a write when the TTL is non-positive", %{key: key} do
      Config.update(cache_ttl: 0)

      :sys.suspend(AuthCache)

      # A suspended GenServer still accepts messages into its mailbox; it just
      # does not process them until resumed. Checking the queue length *while
      # still suspended* is what actually proves nothing was cast — asserting
      # only `put/2`'s return value or a post-resume `get/1` would pass even if
      # put/2 cast unconditionally: `GenServer.cast/2` always returns `:ok`
      # against a suspended (but alive) process, and `get/1` reports `:miss`
      # for any key while cache_ttl <= 0 regardless of what is in ETS.
      queue_length =
        try do
          assert AuthCache.put(key, {"app-env-1", nil}) == :ok
          Process.info(Process.whereis(AuthCache), :message_queue_len)
        after
          :sys.resume(AuthCache)
        end

      assert queue_length == {:message_queue_len, 0}

      sync()

      # Confirm via the table itself, not AuthCache.get/1, that nothing landed
      # — get/1 would report :miss either way while disabled.
      assert :ets.lookup(:epb_auth_cache, key) == []
    end
  end

  describe "size cap" do
    test "evicts rather than growing without bound", %{key: key} do
      keys = for i <- 1..(@max_size + 1), do: "#{key}:#{i}"

      Enum.each(keys, &AuthCache.put(&1, {"app-env-1", nil}))
      sync()

      retained = Enum.count(keys, &match?({:hit, _}, AuthCache.get(&1)))

      # An unbounded cache is a slow memory leak in the host application: one
      # entry per (caller, route, method, version) combination, kept for the TTL.
      assert retained <= @max_size
      assert retained < length(keys)
      assert AuthCache.get(List.last(keys)) != :miss
    end
  end
end
