defmodule EndPointBlank.Config do
  @moduledoc """
  Singleton configuration store for the EndPointBlank library.

  Update via `EndPointBlank.configure/1`.

  ## Reads do not go through a process

  This config is read-mostly to an extreme degree: it is written by
  `EndPointBlank.configure/1`, usually once at boot, and read on every inbound
  request (the authorization plug, the version finder) and every outbound write
  (each writer, the masking layer, every URL builder). The two sides are
  therefore stored differently.

  Writes go through an Agent, which is the **writer of record**. It serialises
  concurrent `update/1` calls so each one's read-modify-write is atomic, and it
  owns the ETS table below, so the config still dies with the process — a
  restart starts from a blank `%EndPointBlank.Config{}` exactly as it did when
  the Agent was the only store.

  Reads go straight to that table: a `:protected`, `read_concurrency` set that
  only the Agent writes. `get/0` is a lock-free lookup performed *in the calling
  process*, so config reads no longer serialise behind one mailbox — and, the
  reason this matters more than the speed, a slow, wedged or restarting Agent
  can no longer take its readers with it. `Agent.get/2` carries a 5000 ms
  default timeout and a timeout **exits the caller**: until sc-350, every
  authorization plug call and every writer was one busy Agent away from dying.
  sc-331 had to catch that exit in `EndPointBlank.Writers.DelayedWriter` for
  precisely this reason.

  ## There is deliberately no fallback

  If the store is unavailable, `get/0` raises. It does not quietly return a
  default `%EndPointBlank.Config{}`: that would authorize requests against
  `nil` credentials and ship telemetry to the public default base URL because a
  process happened to be down, which is a far worse failure than a raise and
  exactly the silent fallback this library refuses.

  ## Environment variables

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

  # The read path. Named for this module so a stray table is attributable at a
  # glance in `:ets.i/0`; the Agent process owns it and is the only writer.
  @table __MODULE__
  @key :config

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
    trust_proxy_headers: true,
    masking_rules: []
  ]

  def start_link(_opts) do
    Agent.start_link(&init_store/0, name: __MODULE__)
  end

  # Runs *in* the Agent process, which is what makes the Agent the table's
  # owner: the table is destroyed when that process dies, so an unavailable
  # config reads as unavailable rather than as a stale copy left behind by a
  # process that has already gone.
  defp init_store do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    publish(%__MODULE__{})
  end

  @doc """
  The current configuration, with `ENDPOINTBLANK_*` fallbacks applied.

  A direct ETS read in the calling process — no message is sent to the Agent,
  so this can neither queue behind a config write nor exit on a call timeout.

  Raises if the store is unavailable; see the module doc for why it does not
  fall back to a default config.
  """
  def get do
    case :ets.whereis(@table) do
      :undefined ->
        raise "EndPointBlank.Config is unavailable, so configuration cannot be read. " <>
                "The store is created by the :end_point_blank_elixir application's " <>
                "supervisor, so either that application is not started or the config " <>
                "process is down. Refusing to fall back to a default config: that would " <>
                "mean authorizing against nil credentials and writing to the default " <>
                "base URL."

      table ->
        # The row is written before the Agent finishes starting, so a live table
        # always has it. The match states that rather than tolerating a miss.
        [{@key, config}] = :ets.lookup(table, @key)
        resolve(config)
    end
  end

  @doc """
  Merges `opts` into the stored config, ignoring keys that are not settings.

  Serialised through the Agent, and synchronous: once this returns, every
  process reading `get/0` sees the new value.
  """
  def update(opts) when is_list(opts) do
    Agent.update(__MODULE__, fn config ->
      opts
      |> Enum.reduce(config, fn {k, v}, acc ->
        if Map.has_key?(acc, k), do: Map.put(acc, k, v), else: acc
      end)
      |> publish()
    end)
  end

  @doc false
  def reset, do: Agent.update(__MODULE__, fn _ -> publish(%__MODULE__{}) end)

  # The one place the read path is written. It runs in the Agent process — the
  # only process a `:protected` table lets write — and returns the config so it
  # is also the Agent's new state. Table and state therefore cannot drift:
  # there is no way to set one without setting the other.
  defp publish(%__MODULE__{} = config) do
    true = :ets.insert(@table, {@key, config})
    config
  end

  # Applies the ENDPOINTBLANK_* env-var fallback (and built-in defaults)
  # to a stored config, without mutating what's actually stored. Reading
  # System.get_env/1 here (rather than caching it in the struct) lets
  # tests toggle env vars per-example, and lets a deployment change one at
  # runtime. That is why the ETS row holds the *stored* config and this runs on
  # every read: caching the resolved struct would be faster and would silently
  # freeze the environment at whatever it was when `configure/1` last ran.
  #
  # It costs almost nothing in a configured host, because `||` short-circuits:
  # a setting that was configured explicitly never reaches `System.get_env/1`.
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
