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
