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
end
