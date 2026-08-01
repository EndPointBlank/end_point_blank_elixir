defmodule EndPointBlank.AuthCacheTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.{AuthCache, Config}

  @max_size 1_000

  setup do
    on_exit(&Config.reset/0)

    # The table is process-wide and has no public clear, so every test works on
    # keys nothing else will collide with.
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
