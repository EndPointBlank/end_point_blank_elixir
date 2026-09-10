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
end
