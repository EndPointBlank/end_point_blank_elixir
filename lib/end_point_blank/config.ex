defmodule EndPointBlank.Config do
  @moduledoc """
  Singleton configuration store for the EndPointBlank library.

  Backed by an Agent so all processes share the same config.
  Update via `EndPointBlank.configure/1`.

  Several settings also fall back to `ENDPOINTBLANK_*` environment
  variables when not explicitly configured, in order to support
  Rails-free (and Elixir-config-free) deployments. Precedence for each
  such setting is: explicit value set via `EndPointBlank.configure/1` >
  `System.get_env/1` > built-in default. The environment variable is
  read at getter time (not cached), so it can be changed at runtime.
  """

  use Agent

  @default_base_url "https://in.endpointblank.com"
  @default_log_base_url "https://log.endpointblank.com"

  defstruct [
    :client_id,
    :client_secret,
    :app_name,
    :environment,
    :application_version,
    :version_finder,
    :token_ttl,
    :mask_hook,
    :base_url,
    :log_base_url,
    log_mode: :direct,
    worker_count: 4,
    cache_ttl: 300,
    masking_rules: []
  ]

  def start_link(_opts) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  def get, do: Agent.get(__MODULE__, &resolve/1)

  def update(opts) when is_list(opts) do
    Agent.update(__MODULE__, fn config ->
      Enum.reduce(opts, config, fn {k, v}, acc ->
        if Map.has_key?(acc, k), do: Map.put(acc, k, v), else: acc
      end)
    end)
  end

  @doc false
  def reset, do: Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)

  # Applies the ENDPOINTBLANK_* env-var fallback (and built-in defaults)
  # to a stored config, without mutating what's actually stored. Reading
  # System.get_env/1 here (rather than caching it in the struct) lets
  # tests toggle env vars per-example.
  defp resolve(config) do
    %{
      config
      | client_id: config.client_id || System.get_env("ENDPOINTBLANK_CLIENT_ID"),
        client_secret: config.client_secret || System.get_env("ENDPOINTBLANK_CLIENT_SECRET"),
        base_url:
          config.base_url || System.get_env("ENDPOINTBLANK_BASE_URL") || @default_base_url,
        log_base_url:
          config.log_base_url || System.get_env("ENDPOINTBLANK_LOG_BASE_URL") ||
            @default_log_base_url,
        app_name: config.app_name || System.get_env("ENDPOINTBLANK_APP_NAME"),
        environment: config.environment || System.get_env("ENDPOINTBLANK_ENV")
    }
  end

  # Config readers

  def masking_rules, do: get().masking_rules
  def mask_hook, do: get().mask_hook

  @doc """
  Max number of concurrent writes `DelayedWriter` performs per flush tick.
  Falls back to the struct default (4) if unset or invalid.
  """
  def worker_count do
    case get().worker_count do
      n when is_integer(n) and n > 0 -> n
      _ -> 4
    end
  end

  # URL builders

  def authorize_url, do: get().base_url <> "/api/authorize"
  def endpoint_update_url, do: get().base_url <> "/api/application_updates"
  def access_token_url, do: get().base_url <> "/api/access_token"
  def requests_url, do: get().log_base_url <> "/api/application_requests"
  def responses_url, do: get().log_base_url <> "/api/application_responses"
  def logs_url, do: get().log_base_url <> "/api/application_logs"
  def errors_url, do: get().log_base_url <> "/api/application_errors"
end
