defmodule EndPointBlankTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.Config

  setup do
    Config.reset()
    on_exit(&Config.reset/0)
    :ok
  end

  describe "configure/1" do
    test "applies every documented option" do
      EndPointBlank.configure(
        base_url: "https://in.example.com",
        log_base_url: "https://log.example.com",
        client_id: "cid",
        client_secret: "csecret",
        app_name: "my-app",
        environment: "staging",
        application_version: "abc1234",
        log_mode: :delayed,
        token_ttl: 900
      )

      config = Config.get()

      assert config.base_url == "https://in.example.com"
      assert config.log_base_url == "https://log.example.com"
      assert config.client_id == "cid"
      assert config.client_secret == "csecret"
      assert config.app_name == "my-app"
      assert config.environment == "staging"
      assert config.application_version == "abc1234"
      assert config.log_mode == :delayed
      assert config.token_ttl == 900
    end

    test "merges with what is already configured rather than replacing it" do
      # Hosts commonly configure in two places — a base call plus an
      # environment-specific override — and expect the first to survive.
      EndPointBlank.configure(app_name: "my-app", environment: "staging")
      EndPointBlank.configure(environment: "production")

      assert Config.get().app_name == "my-app"
      assert Config.get().environment == "production"
    end

    test "ignores an unknown option instead of crashing the host's boot" do
      EndPointBlank.configure(app_name: "my-app", not_a_real_setting: true)

      assert Config.get().app_name == "my-app"
      refute Map.has_key?(Config.get(), :not_a_real_setting)
    end

    test "leaves defaults in place for options not given" do
      EndPointBlank.configure(app_name: "my-app")

      config = Config.get()
      assert config.log_mode == :direct
      assert config.cache_ttl == 300
      assert config.masking_rules == []
    end
  end

  describe "version/0" do
    test "reports a semantic version string" do
      assert EndPointBlank.version() =~ ~r/^\d+\.\d+\.\d+/
    end

    test "reports the version mix.exs publishes" do
      # Anchored to the manifest, not to the value version/0 is built from.
      # This module used to carry its own @version literal, which sat at 0.3.2
      # while mix.exs shipped 0.4.0 — a shape-only assertion passed the whole
      # time, so every payload named a version that was never released.
      assert EndPointBlank.version() == Mix.Project.config()[:version]
    end

    test "is not restated as a literal anywhere in lib/" do
      # The guard that actually matters. Correcting the value is a one-time
      # fix; what let it rot was the version living in two hand-maintained
      # copies. Reading the app spec only helps while nothing reintroduces a
      # literal, so fail the build rather than trusting reviewers to notice.
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~r/@version\s+"\d+\.\d+/))

      assert offenders == []
    end
  end

  describe "worker_count/0" do
    test "uses the configured value" do
      EndPointBlank.configure(worker_count: 8)

      assert Config.worker_count() == 8
    end

    test "falls back to the default when the value is not a usable count" do
      # A zero or negative max_concurrency raises inside Task.async_stream, which
      # would take down the DelayedWriter on every flush.
      for bad <- [0, -1, "four", nil] do
        EndPointBlank.configure(worker_count: bad)
        assert Config.worker_count() == 4
      end
    end
  end

  describe "config readers" do
    test "masking_rules/0 and mask_hook/0 expose what was configured" do
      hook = fn payload, _type -> payload end
      rules = [%{target: "request_body", path: "$.a", regex: nil, replacement_value: "x"}]

      EndPointBlank.configure(masking_rules: rules, mask_hook: hook)

      assert Config.masking_rules() == rules
      assert Config.mask_hook() == hook
    end
  end

  describe "URL builders" do
    setup do
      EndPointBlank.configure(
        base_url: "https://in.example.com",
        log_base_url: "https://log.example.com"
      )

      :ok
    end

    test "authorization and update endpoints hang off base_url" do
      assert Config.authorize_url() == "https://in.example.com/api/authorize"
      assert Config.endpoint_update_url() == "https://in.example.com/api/application_updates"
      assert Config.access_token_url() == "https://in.example.com/api/access_token"
    end

    test "telemetry endpoints hang off log_base_url" do
      # Logging is split onto its own host so telemetry volume never contends
      # with the authorization path.
      assert Config.requests_url() == "https://log.example.com/api/application_requests"
      assert Config.responses_url() == "https://log.example.com/api/application_responses"
      assert Config.logs_url() == "https://log.example.com/api/application_logs"
      assert Config.errors_url() == "https://log.example.com/api/application_errors"
    end
  end
end
