defmodule EndPointBlank.Management do
  @moduledoc """
  A client for the EndPointBlank organization management API (`/api/v1`,
  sc-1504): your organization, API packages, clients and what they hold,
  applications, environments, runtime credentials and managed clients.

  It is separate from the runtime SDK on purpose. It reads none of
  `EndPointBlank.configure/1`'s settings and sends none of them: the only
  credential it sends is the management key you give it, as
  `Authorization: Bearer epb_mk_...`, and only to `:base_url`. Create a
  management key in the portal; keys cannot be created through the API.

      mgmt = EndPointBlank.Management.new(key: System.fetch_env!("EPB_MGMT_KEY"))

      {:ok, organization} = EndPointBlank.Management.Organization.get(mgmt)

  One module per resource, each taking this client first:

    * `EndPointBlank.Management.Organization`
    * `EndPointBlank.Management.ApiPackages` (and what a package publishes)
    * `EndPointBlank.Management.Endpoints`
    * `EndPointBlank.Management.Clients`
    * `EndPointBlank.Management.ClientPackages`
    * `EndPointBlank.Management.ClientGrants`
    * `EndPointBlank.Management.Applications`
    * `EndPointBlank.Management.ApplicationEnvironments`
    * `EndPointBlank.Management.Environments`
    * `EndPointBlank.Management.Credentials`
    * `EndPointBlank.Management.ManagedClients`

  ## Results

  Every call answers `{:ok, result}` or `{:error, %EndPointBlank.Management.Error{}}`
  and never raises. `result` is the API's `data`, decoded JSON with string
  keys. A list call answers one `EndPointBlank.Management.Page`; the matching
  `stream` function pages through all of them lazily and raises the error
  instead, since a stream cannot answer a tuple.

  ## Retries and idempotency

  Every POST sends an `Idempotency-Key`: a random UUID, or the one passed as
  `idempotency_key:`. A retry sends the same key, so the API runs the request
  once. The client retries, up to `:max_retries` times:

    * a `429 rate_limited` answer, after its `Retry-After` seconds (any method);
    * a `409 idempotency_request_in_progress` answer (a POST);
    * a 5xx answer or a request that got no answer, for GET, DELETE and POST
      only. A PATCH is never retried for these.

  `409 idempotency_replay_unavailable` is never retried: the first request
  succeeded and its answer held a credential secret shown once. Get or list
  the credential instead.

  ## Managed clients

  `for_managed_client/2` gives a client that acts on one of your unclaimed
  managed clients' applications, environments and credentials, under
  `/api/v1/clients/:client_id/...`.
  """

  alias EndPointBlank.Management.Error

  @default_base_url "https://app.endpointblank.com"
  @key_format ~r/\Aepb_mk_[A-Za-z0-9_-]+\z/

  @derive {Inspect, except: [:key]}
  @enforce_keys [:key]
  defstruct key: nil,
            base_url: @default_base_url,
            max_retries: 2,
            max_retry_wait_ms: 60_000,
            receive_timeout: 15_000,
            sleep: &Process.sleep/1,
            req_options: [],
            managed_client_id: nil

  @type t :: %__MODULE__{
          key: String.t(),
          base_url: String.t(),
          max_retries: non_neg_integer(),
          max_retry_wait_ms: non_neg_integer(),
          receive_timeout: pos_integer(),
          sleep: (non_neg_integer() -> any()),
          req_options: keyword(),
          managed_client_id: String.t() | nil
        }

  @typedoc "What every management call answers."
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc """
  Builds a management client. Raises `ArgumentError` for a bad option; the
  message never repeats the key.

  Options:

    * `:key` (required) -- a management API key, `epb_mk_...`.
    * `:base_url` -- defaults to `#{@default_base_url}`.
    * `:max_retries` -- how many times one call is retried (see the module
      docs). Defaults to 2; `0` turns retries off.
    * `:max_retry_wait_ms` -- the longest `Retry-After` the client waits out
      (default 60 000). A longer one is answered as the `rate_limited` error,
      with `:retry_after` set.
    * `:receive_timeout` -- per attempt, in milliseconds (default 15 000).
    * `:sleep` -- the function that waits between retries, given
      milliseconds. Defaults to `Process.sleep/1`; tests pass their own.
    * `:req_options` -- extra `Req` options for every request (for example
      `plug:` in tests). Options this client sets itself win, and `:auth` is
      dropped: the only credential sent is the management key.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    key = Keyword.get(opts, :key)

    unless valid_key?(key) do
      raise ArgumentError,
            "EndPointBlank.Management needs a management API key (epb_mk_...) as :key; " <>
              "the value given is not one (check for a trailing newline or space). " <>
              "Runtime client credentials can't be used here."
    end

    %__MODULE__{
      key: key,
      base_url: base_url!(Keyword.get(opts, :base_url, @default_base_url)),
      max_retries: non_neg_integer!(opts, :max_retries, 2),
      max_retry_wait_ms: non_neg_integer!(opts, :max_retry_wait_ms, 60_000),
      receive_timeout: pos_integer!(opts, :receive_timeout, 15_000),
      sleep: sleep!(Keyword.get(opts, :sleep, &Process.sleep/1)),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc """
  A client that acts on your managed client `client_id`'s organization: the
  `Applications`, `ApplicationEnvironments`, `Environments` and `Credentials`
  modules then call `/api/v1/clients/:client_id/...`. Every other module
  refuses it with `"not_available_for_managed_client"`, without a request.

  The API answers 404 once the customer has claimed the client.
  """
  @spec for_managed_client(t(), String.t()) :: t()
  def for_managed_client(%__MODULE__{} = client, client_id)
      when is_binary(client_id) and client_id != "" do
    %{client | managed_client_id: client_id}
  end

  @doc "The base URL every call goes to."
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{base_url: base_url}), do: base_url

  # Keys are minted as "epb_mk_" plus URL-safe base64, so anything else -- a
  # trailing newline from a secrets file, a space, a control byte -- is not a
  # key, and is refused here rather than failing later as a transport error.
  defp valid_key?(key) when is_binary(key), do: Regex.match?(@key_format, key)

  defp valid_key?(_key), do: false

  defp base_url!(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        String.trim_trailing(url, "/")

      _other ->
        raise ArgumentError, ":base_url must be an absolute http or https URL"
    end
  end

  defp base_url!(_url),
    do: raise(ArgumentError, ":base_url must be an absolute http or https URL")

  defp non_neg_integer!(opts, name, default) do
    case Keyword.get(opts, name, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> raise ArgumentError, "#{inspect(name)} must be a non-negative integer"
    end
  end

  defp pos_integer!(opts, name, default) do
    case Keyword.get(opts, name, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> raise ArgumentError, "#{inspect(name)} must be a positive integer"
    end
  end

  defp sleep!(fun) when is_function(fun, 1), do: fun
  defp sleep!(_other), do: raise(ArgumentError, ":sleep must be a function of one argument")
end
