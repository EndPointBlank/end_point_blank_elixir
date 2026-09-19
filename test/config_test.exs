defmodule EndPointBlank.ConfigTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.Config

  @default_base_url "https://in.endpointblank.com"
  @default_log_base_url "https://log.endpointblank.com"

  # The Config store is a singleton Agent shared across the whole test
  # suite (started by the application supervisor), and ENDPOINTBLANK_* env
  # vars are process-global. Run serially and always leave both pristine.
  setup do
    Config.reset()

    on_exit(fn ->
      Config.reset()

      for var <- ~w(
            ENDPOINTBLANK_CLIENT_ID
            ENDPOINTBLANK_CLIENT_SECRET
            ENDPOINTBLANK_BASE_URL
            ENDPOINTBLANK_LOG_BASE_URL
            ENDPOINTBLANK_APP_NAME
            ENDPOINTBLANK_ENV
          ) do
        System.delete_env(var)
      end
    end)

    :ok
  end

  describe "client_id" do
    test "falls back to ENDPOINTBLANK_CLIENT_ID when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_CLIENT_ID", "env-client-id")
      assert Config.get().client_id == "env-client-id"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_CLIENT_ID", "env-client-id")
      Config.update(client_id: "explicit-client-id")
      assert Config.get().client_id == "explicit-client-id"
    end

    test "is nil when neither explicit value nor env var is set" do
      assert Config.get().client_id == nil
    end
  end

  describe "client_secret" do
    test "falls back to ENDPOINTBLANK_CLIENT_SECRET when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_CLIENT_SECRET", "env-secret")
      assert Config.get().client_secret == "env-secret"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_CLIENT_SECRET", "env-secret")
      Config.update(client_secret: "explicit-secret")
      assert Config.get().client_secret == "explicit-secret"
    end

    test "is nil when neither explicit value nor env var is set" do
      assert Config.get().client_secret == nil
    end
  end

  describe "base_url" do
    test "falls back to ENDPOINTBLANK_BASE_URL when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_BASE_URL", "https://env.example.com")
      assert Config.get().base_url == "https://env.example.com"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_BASE_URL", "https://env.example.com")
      Config.update(base_url: "https://explicit.example.com")
      assert Config.get().base_url == "https://explicit.example.com"
    end

    test "falls back to the built-in default when neither is set" do
      assert Config.get().base_url == @default_base_url
    end

    test "env var wins over the built-in default" do
      System.put_env("ENDPOINTBLANK_BASE_URL", "https://env.example.com")
      refute Config.get().base_url == @default_base_url
    end

    test "URL builders reflect the env-derived base_url" do
      System.put_env("ENDPOINTBLANK_BASE_URL", "https://env.example.com")
      assert Config.authorize_url() == "https://env.example.com/api/authorize"
    end
  end

  describe "log_base_url" do
    test "falls back to ENDPOINTBLANK_LOG_BASE_URL when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_LOG_BASE_URL", "https://env-log.example.com")
      assert Config.get().log_base_url == "https://env-log.example.com"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_LOG_BASE_URL", "https://env-log.example.com")
      Config.update(log_base_url: "https://explicit-log.example.com")
      assert Config.get().log_base_url == "https://explicit-log.example.com"
    end

    test "falls back to the built-in default when neither is set" do
      assert Config.get().log_base_url == @default_log_base_url
    end

    test "env var wins over the built-in default" do
      System.put_env("ENDPOINTBLANK_LOG_BASE_URL", "https://env-log.example.com")
      refute Config.get().log_base_url == @default_log_base_url
    end

    test "URL builders reflect the env-derived log_base_url" do
      System.put_env("ENDPOINTBLANK_LOG_BASE_URL", "https://env-log.example.com")
      assert Config.requests_url() == "https://env-log.example.com/api/application_requests"
    end
  end

  describe "app_name" do
    test "falls back to ENDPOINTBLANK_APP_NAME when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_APP_NAME", "env-app")
      assert Config.get().app_name == "env-app"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_APP_NAME", "env-app")
      Config.update(app_name: "explicit-app")
      assert Config.get().app_name == "explicit-app"
    end

    test "is nil when neither explicit value nor env var is set" do
      assert Config.get().app_name == nil
    end
  end

  describe "environment" do
    test "falls back to ENDPOINTBLANK_ENV when not explicitly configured" do
      System.put_env("ENDPOINTBLANK_ENV", "env-staging")
      assert Config.get().environment == "env-staging"
    end

    test "explicit configuration wins over the env var" do
      System.put_env("ENDPOINTBLANK_ENV", "env-staging")
      Config.update(environment: "explicit-staging")
      assert Config.get().environment == "explicit-staging"
    end

    test "is nil when neither explicit value nor env var is set" do
      assert Config.get().environment == nil
    end
  end

  # sc-350. `get/0` sits in the hot path of every inbound request and every
  # outbound write. It used to be `Agent.get(__MODULE__, &resolve/1)`, which
  # serialised all of that through one mailbox and — worse — carried
  # `Agent.get/2`'s 5000 ms default timeout, and a call timeout *exits the
  # caller*. A merely busy config process was therefore able to kill an
  # authorization plug mid-request. These tests pin the read path itself, not
  # the values it returns.
  describe "the read path" do
    test "a read answers while the config process is wedged" do
      Config.update(app_name: "written-before-the-block")
      config = Process.whereis(Config)
      test_pid = self()

      # A real block, not a simulated one: this cast occupies the config
      # process until it is released, exactly as a slow write or a restart
      # would. Every `Agent.get/2` issued meanwhile queues behind it.
      Agent.cast(config, fn state ->
        send(test_pid, :config_blocked)

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        state
      end)

      assert_receive :config_blocked, 1_000
      on_exit(fn -> send(config, :release) end)

      {micros, read} = :timer.tc(fn -> Config.get() end)

      assert read.app_name == "written-before-the-block"

      # The old read would have waited out the block and then exited its
      # caller. Half a second is generous for what is now an ETS lookup, and
      # nowhere near the five seconds a queued read would have taken.
      assert micros < 500_000,
             "a config read waited #{div(micros, 1_000)}ms on the config process"

      # And it is really the process that was blocked, not the test being
      # optimistic: a call to it does time out while a read does not.
      assert catch_exit(Agent.get(config, & &1, 50))
    end

    test "a read raises rather than handing back a default config when the store is down" do
      # The cheap fix for sc-350 — a try/catch around the read falling back to
      # `%Config{}` — would hand every caller nil credentials and the public
      # default base URL whenever the store was merely unavailable. A plug that
      # authorizes against nil credentials is a worse failure than one that
      # raises, so this must stay loud.
      :ok = Supervisor.terminate_child(EndPointBlank.Supervisor, Config)

      try do
        error = assert_raise RuntimeError, fn -> Config.get() end

        assert error.message =~ "EndPointBlank.Config is unavailable"
        assert error.message =~ "Refusing to fall back to a default config"

        # Every reader built on get/0 fails the same way. None of them quietly
        # answers with a default.
        assert_raise RuntimeError, fn -> Config.authorize_url() end
        assert_raise RuntimeError, fn -> Config.requests_url() end
        assert_raise RuntimeError, fn -> Config.masking_rules() end
        assert_raise RuntimeError, fn -> Config.worker_count() end
      after
        {:ok, _pid} = Supervisor.restart_child(EndPointBlank.Supervisor, Config)
      end

      assert Config.get().base_url == @default_base_url
    end

    test "the env var is re-read on every read, not frozen at write time" do
      # The reason the stored config is cached and the *resolved* config is
      # not. Nothing writes config between these three reads; the value changes
      # anyway, because resolve/1 runs on the read.
      assert Config.get().app_name == nil

      System.put_env("ENDPOINTBLANK_APP_NAME", "env-app")
      assert Config.get().app_name == "env-app"

      System.delete_env("ENDPOINTBLANK_APP_NAME")
      assert Config.get().app_name == nil
    end

    test "a write is visible to other processes as soon as update/1 returns" do
      Config.update(app_name: "written-here")

      assert Task.async(fn -> Config.get().app_name end) |> Task.await() == "written-here"

      Config.reset()

      assert Task.async(fn -> Config.get().app_name end) |> Task.await() == nil
    end

    test "a restarted config process starts blank rather than serving what it held" do
      # The read cache is owned by the config process, so it dies with it. If
      # it outlived the process, a restart would silently resurrect credentials
      # the supervisor had just discarded.
      Config.update(client_id: "before-the-restart")

      :ok = Supervisor.terminate_child(EndPointBlank.Supervisor, Config)
      {:ok, _pid} = Supervisor.restart_child(EndPointBlank.Supervisor, Config)

      assert Config.get().client_id == nil
    end
  end

  # A misspelled or obsolete key used to be dropped on the floor by
  # `Enum.reduce/3`'s `Map.has_key?/2` guard: `configure(client_secert: "x")`
  # silently ran with `client_secret: nil`, and `configure(base_uri: "...")`
  # silently kept the public default `base_url`. Both are the "boots clean and
  # is quietly wrong" shape this project's no-silent-failures rule exists to
  # prevent, so `update/1` now refuses instead.
  describe "update/1 rejects unknown keys" do
    test "raises ArgumentError naming the unknown key" do
      error =
        assert_raise ArgumentError, fn ->
          Config.update(client_secert: "typo'd-secret")
        end

      assert error.message =~ "client_secert"
    end

    test "a mix of valid and unknown keys raises and applies neither" do
      Config.update(app_name: "before")

      assert_raise ArgumentError, fn ->
        Config.update(app_name: "after", base_uri: "https://typo.example.com")
      end

      # The valid key in the same call was not applied either: the update is
      # all-or-nothing, not best-effort.
      assert Config.get().app_name == "before"
    end

    test "the config process survives the raise, and get/0 still works" do
      # Validation runs in the calling process, before Agent.update/2 is ever
      # called. If it instead ran inside the Agent's update function, the
      # raise would crash the Agent that owns the config ETS table — taking
      # the whole config store down with it, not just this call. Assert on
      # the process directly, not only that get/0 happens to still answer.
      config_pid = Process.whereis(Config)

      assert_raise ArgumentError, fn -> Config.update(not_a_real_setting: true) end

      assert Process.alive?(config_pid)
      assert Process.whereis(Config) == config_pid
      assert %Config{} = Config.get()
    end

    test "rejects :__struct__" do
      error =
        assert_raise ArgumentError, fn ->
          Config.update(__struct__: NotTheRealConfigStruct)
        end

      assert error.message =~ "__struct__"
    end

    test "every currently valid key is still accepted" do
      # Each key is written with its own struct default, which is a valid value
      # by definition. `nil` used to be written here for every key, but an
      # explicit `cache_ttl: nil` is now itself rejected (sc-970, below), which
      # would make this test about value validation rather than key validation.
      for {key, default} <- Map.from_struct(%Config{}) do
        assert Config.update([{key, default}]) == :ok
      end
    end
  end

  # sc-970: one rule for `cache_ttl`, identical in the JS, Java, Elixir, Python
  # and Rails SDKs. Omitting it means the default of 300 seconds; 0 disables
  # the authorization cache; anything else that is not a non-negative integer
  # -- an explicit nil, a negative number, a float, a string -- raises at
  # configure time, not at first cache use.
  #
  # Before this, `update/1` validated keys but never values. `nil` and a string
  # were stored as given and then silently turned into a 300 s TTL by a rescue
  # in `EndPointBlank.AuthCache`, a float was used as a fractional TTL, and a
  # negative number silently disabled the cache.
  describe "cache_ttl (sc-970)" do
    test "omitted, it is the default of 300 seconds" do
      EndPointBlank.configure(app_name: "my-app")

      assert Config.get().cache_ttl == 300
    end

    test "an explicit nil raises at configure time, naming cache_ttl and pointing at omission" do
      error =
        assert_raise ArgumentError, fn ->
          EndPointBlank.configure(cache_ttl: nil)
        end

      assert error.message =~ ":cache_ttl"
      assert error.message =~ "nil"
      assert error.message =~ "omit"
      assert error.message =~ "300"

      # Rejected, not stored: nothing reaches the config for AuthCache to
      # reinterpret later.
      assert Config.get().cache_ttl == 300
    end

    test "0 is accepted and disables the authorization cache" do
      assert EndPointBlank.configure(cache_ttl: 0) == :ok
      assert Config.get().cache_ttl == 0

      key = "epb_auth:sc-970:#{System.unique_integer([:positive])}"
      assert EndPointBlank.AuthCache.put(key, {"app-env-1", nil}) == :ok
      :sys.get_state(EndPointBlank.AuthCache)

      assert EndPointBlank.AuthCache.get(key) == :miss
      assert :ets.lookup(:epb_auth_cache, key) == []
    end

    test "a positive integer is accepted as a TTL in seconds" do
      assert EndPointBlank.configure(cache_ttl: 1) == :ok
      assert Config.get().cache_ttl == 1

      assert EndPointBlank.configure(cache_ttl: 3_600) == :ok
      assert Config.get().cache_ttl == 3_600
    end

    test "a negative integer raises at configure time instead of disabling the cache" do
      for bad <- [-1, -5, -300] do
        error =
          assert_raise ArgumentError, fn ->
            EndPointBlank.configure(cache_ttl: bad)
          end

        assert error.message =~ ":cache_ttl"
        assert error.message =~ inspect(bad)
        assert Config.get().cache_ttl == 300
      end
    end

    test "a non-integer raises at configure time: strings, floats, and anything else" do
      # 300.0 is included on purpose: an integral float is still not an
      # integer, and used to be accepted as a float TTL. "300" is the shape an
      # unconverted environment variable arrives in.
      for bad <- ["abc", "300", 3.5, 300.0, -0.5, true, :infinity, [300]] do
        error =
          assert_raise ArgumentError, fn ->
            EndPointBlank.configure(cache_ttl: bad)
          end

        assert error.message =~ ":cache_ttl"
        assert error.message =~ inspect(bad)
        assert Config.get().cache_ttl == 300
      end
    end

    test "a rejected cache_ttl applies nothing else from the same call" do
      Config.update(app_name: "before", cache_ttl: 60)

      assert_raise ArgumentError, fn ->
        Config.update(app_name: "after", cache_ttl: nil)
      end

      assert Config.get().app_name == "before"
      assert Config.get().cache_ttl == 60
    end

    test "every occurrence of a repeated cache_ttl key is checked, not only the first" do
      # update/1 applies opts in order, so the *last* occurrence is the one that
      # would be stored. Checking only the first (`Keyword.get/2`) would let this
      # through and store nil.
      assert_raise ArgumentError, fn ->
        Config.update(cache_ttl: 60, cache_ttl: nil)
      end

      assert Config.get().cache_ttl == 300
    end

    test "the config process survives a rejected cache_ttl" do
      # Same reasoning as the unknown-key check above: the value check has to
      # run in the caller, before Agent.update/2, or a bad value would crash
      # the Agent that owns the config store.
      config_pid = Process.whereis(Config)

      assert_raise ArgumentError, fn -> Config.update(cache_ttl: -1) end

      assert Process.alive?(config_pid)
      assert Process.whereis(Config) == config_pid
      assert %Config{cache_ttl: 300} = Config.get()
    end
  end

  # Before this change, `update/1`'s `Enum.reduce/3` pattern-matched every
  # element of `opts` as a `{k, v}` tuple *inside* the function passed to
  # `Agent.update/2`. A plain atom element isn't a 2-tuple, so that match
  # failed in the Agent process itself and crashed the store — the same
  # hazard as `:__struct__` above, just reached through a different bad
  # input. A string-keyed tuple didn't crash the old code, but it didn't do
  # anything useful either: `Map.has_key?/2` compared the string against the
  # struct's atom keys, found nothing, and silently dropped it — the same
  # silent no-op this whole change exists to stop. `update/1` now rejects
  # both up front, in the caller, before the Agent is ever touched.
  # sc-1266: the sc-970 reviews found Rails and Java apply part of a
  # `configure` call's settings when a later field fails validation — the
  # fields validated (or merged) before the bad one stay assigned, so a
  # caller who gets an `ArgumentError` is left with a half-updated config.
  # Every SDK was required to add this same test regardless of whether it
  # was already atomic, and to say in its PR which case applies.
  #
  # This SDK's `update/1` (above) already validates every supplied value
  # — `unknown_keys/1` and `validate_cache_ttl!/1` — entirely in the calling
  # process before `Agent.update/2` is ever invoked; the reduce inside
  # `Agent.update/2` is unconditional `Map.put/3` and cannot itself fail.
  # There is no code path that applies some keys and then raises on a later
  # one, so this test is expected to pass unmodified. That was confirmed by
  # mutation, not by reading the source: temporarily moving
  # `validate_cache_ttl!(opts)` to run *after* `Agent.update/2` (reinstating
  # "apply everything, validate last") turns this red with a real assertion
  # failure, which is the regression this test exists to catch.
  describe "configure/1 is all-or-nothing (sc-1266)" do
    test "a call with one valid field and one invalid field raises and applies neither" do
      EndPointBlank.configure(client_id: "prior-client-id")

      assert_raise ArgumentError, fn ->
        EndPointBlank.configure(client_id: "new-client-id", cache_ttl: -1)
      end

      # Proof this is all-or-nothing, not best-effort: the valid field named
      # in the same rejected call was NOT applied. If `configure/1` ever
      # applied fields before validating the rest, this would read
      # "new-client-id" instead.
      assert Config.get().client_id == "prior-client-id"
      assert Config.get().cache_ttl == 300
    end
  end

  describe "update/1 rejects non-keyword lists" do
    test "raises when given a plain atom instead of a {key, value} pair" do
      config_pid = Process.whereis(Config)

      assert_raise ArgumentError, fn -> Config.update([:foo]) end

      assert Process.alive?(config_pid)
      assert Process.whereis(Config) == config_pid
      assert %Config{} = Config.get()
    end

    test "raises when a key is a string instead of an atom" do
      config_pid = Process.whereis(Config)

      assert_raise ArgumentError, fn -> Config.update([{"client_id", "x"}]) end

      assert Process.alive?(config_pid)
      assert Process.whereis(Config) == config_pid
      assert %Config{} = Config.get()
    end
  end
end
