defmodule EndPointBlank.Config do
  @moduledoc """
  Singleton configuration store for the EndPointBlank library.

  Backed by an Agent so all processes share the same config.
  Update via `EndPointBlank.configure/1`.
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
    base_url: @default_base_url,
    log_base_url: @default_log_base_url,
    log_mode: :direct,
    worker_count: 4,
    cache_ttl: 300
  ]

  def start_link(_opts) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  def get, do: Agent.get(__MODULE__, & &1)

  def update(opts) when is_list(opts) do
    Agent.update(__MODULE__, fn config ->
      Enum.reduce(opts, config, fn {k, v}, acc ->
        if Map.has_key?(acc, k), do: Map.put(acc, k, v), else: acc
      end)
    end)
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
