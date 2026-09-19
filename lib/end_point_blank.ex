defmodule EndPointBlank do
  @app :end_point_blank_elixir

  @doc """
  The version of this library, as published in `mix.exs`.

  Read from the loaded application spec rather than restated as a module
  attribute here. The literal was previously duplicated between `mix.exs` and
  this module and the two never agreed: `mix.exs` reached 0.4.0 while this
  reported 0.3.2, so `lib_version` on every endpoint-update payload named a
  version that was never released. The portal answers "which customers run
  which SDK build" from that field.

  The `.app` file this reads is regenerated from `mix.exs` on every compile,
  so there is no baked-in copy that can go stale, and each dependency carries
  its own spec — no ambiguity about whose version is read when this library is
  consumed as a dep.
  """
  @spec version() :: String.t()
  def version do
    case :application.get_key(@app, :vsn) do
      {:ok, vsn} ->
        List.to_string(vsn)

      :undefined ->
        # Only reachable if the application was never loaded (an escript, or a
        # bare `:code` path). Raise rather than return "" — a blank
        # `lib_version` would silently poison the portal's rollout data, which
        # is the failure this function exists to prevent.
        raise "#{inspect(@app)} is not loaded, so its version cannot be determined"
    end
  end

  @doc """
  Configures the EndPointBlank library.

  Raises `ArgumentError` if `opts` contains any key that is not one of the
  options below (see `EndPointBlank.Config.update/1`) — including a
  misspelled or obsolete one — or an invalid `:cache_ttl` (see below).
  Nothing in `opts` is applied when that happens, even the options that were
  fine: a bad `configure/1` call is a boot-time bug, and this library does not
  silently run with a dropped setting instead of surfacing it.

  ## Options

    * `:base_url` - Authorization and update endpoint base URL
    * `:log_base_url` - Logging endpoint base URL
    * `:client_id` - API credential client ID
    * `:client_secret` - API credential client secret
    * `:app_name` - Application identifier sent with every payload
    * `:environment` - Deployment environment (e.g. "development")
    * `:application_version` - App version string (e.g. a git SHA)
    * `:log_mode` - `:direct` (synchronous) or `:delayed` (background queue)
    * `:token_ttl` - Optional access-token TTL in seconds
    * `:version_finder` - Optional 1-arity function for custom version detection
    * `:mask_hook` - Optional post-rule masking hook, `fn payload, record_type -> payload end`
    * `:masking_rules` - Ordered list of masking rule maps (see the README's "Data masking")
    * `:worker_count` - Max concurrent writes `EndPointBlank.Writers.DelayedWriter` performs per flush (default `4`)
    * `:cache_ttl` - Authorization-cache TTL in seconds, `EndPointBlank.AuthCache`. Omit it for
      the default of `300`; `0` disables the cache. Must be a non-negative integer: an explicit
      `nil`, a negative number, a float or a string raises `ArgumentError` here, at configure
      time, rather than being reinterpreted when the cache is first used
    * `:trust_proxy_headers` - Whether the per-request `scheme`/`host`/`port` report honors `x-forwarded-*` headers (default `true`)

  ## Example

      EndPointBlank.configure(
        base_url: "http://localhost:4001",
        log_base_url: "http://localhost:4001",
        client_id: "my-client-id",
        client_secret: "my-client-secret",
        app_name: "my-app",
        environment: "development",
        log_mode: :direct
      )
  """
  def configure(opts) when is_list(opts) do
    EndPointBlank.Config.update(opts)
  end
end
