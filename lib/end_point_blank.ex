defmodule EndPointBlank do
  @version "0.1.0"

  def version, do: @version

  @doc """
  Configures the EndPointBlank library.

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
