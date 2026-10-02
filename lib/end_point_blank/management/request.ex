defmodule EndPointBlank.Management.Request do
  @moduledoc false
  # The one HTTP path every EndPointBlank.Management resource module takes:
  # headers, the Idempotency-Key, retries, error mapping and pagination.
  #
  # `scope` says where a path lives:
  #   * :organization -- only under /api/v1; refused for a managed-client view.
  #   * :managed -- under /api/v1, or /api/v1/clients/:client_id for a
  #     managed-client view (`EndPointBlank.Management.for_managed_client/2`).
  #
  # Nothing here logs: a request carries the management key and a credential
  # answer carries a secret.

  alias EndPointBlank.Http
  alias EndPointBlank.Management
  alias EndPointBlank.Management.{Error, Page}

  # Methods retried after a 5xx or a request that got no answer. A POST is
  # safe because it always carries an Idempotency-Key; a PATCH is not.
  @retry_on_failure [:get, :delete, :post]

  @max_limit 100

  @doc false
  def get(client, scope, segments, params \\ []),
    do: call(client, scope, :get, segments, params: params)

  @doc false
  def post(client, scope, segments, attrs, opts) do
    with {:ok, body} <- body(attrs) do
      call(client, scope, :post, segments,
        json: body,
        idempotency_key: idempotency_key(opts)
      )
    end
  end

  @doc false
  def patch(client, scope, segments, attrs) do
    with {:ok, body} <- body(attrs) do
      call(client, scope, :patch, segments, json: body)
    end
  end

  @doc false
  def delete(client, scope, segments), do: call(client, scope, :delete, segments, [])

  @doc false
  # The `data` of a single-resource answer.
  def data({:ok, %{"data" => data}}), do: {:ok, data}
  def data({:ok, _body}), do: {:error, unexpected_body()}
  def data({:error, %Error{}} = error), do: error

  @doc false
  # `data` and `warnings` of an answer that carries both (adding an endpoint
  # to, or removing one from, an API package).
  def data_with_warnings({:ok, %{"data" => data} = body}),
    do: {:ok, %{data: data, warnings: Map.get(body, "warnings") || []}}

  def data_with_warnings({:ok, _body}), do: {:error, unexpected_body()}
  def data_with_warnings({:error, %Error{}} = error), do: error

  @doc false
  # One page of a list. `filters` names the query parameters, beyond `limit`
  # and `after`, this list takes from `opts`.
  def page(client, scope, segments, opts, filters \\ []) do
    with {:ok, params} <- list_params(opts, filters),
         {:ok, body} <- get(client, scope, segments, params) do
      to_page(body)
    end
  end

  @doc false
  # Every item of every page, fetched a page at a time as the stream is
  # consumed. Raises the `Error` of a page that fails.
  def stream(client, scope, segments, opts, filters \\ []) do
    Stream.resource(
      fn -> {:next, Keyword.get(opts, :after)} end,
      fn
        :done ->
          {:halt, :done}

        {:next, cursor} ->
          case page(client, scope, segments, Keyword.put(opts, :after, cursor), filters) do
            {:ok, %Page{data: data, next_cursor: nil}} -> {data, :done}
            {:ok, %Page{data: data, next_cursor: next_cursor}} -> {data, {:next, next_cursor}}
            {:error, %Error{} = error} -> raise error
          end
      end,
      fn _state -> :ok end
    )
  end

  @doc false
  # A random (version 4) UUID, for an Idempotency-Key.
  def uuid4 do
    <<a::48, _version::4, b::12, _variant::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  @doc false
  def user_agent, do: "end_point_blank_elixir/#{Http.sdk_version()} (management)"

  defp call(%Management{} = client, scope, method, segments, opts) do
    with {:ok, path} <- resolve(client, scope, segments) do
      attempt(client, method, request_options(client, method, path, opts), 0)
    end
  end

  defp resolve(%Management{managed_client_id: nil}, _scope, segments),
    do: encode_path(segments)

  defp resolve(%Management{managed_client_id: client_id}, :managed, segments),
    do: encode_path(["clients", client_id | segments])

  defp resolve(%Management{}, :organization, _segments) do
    {:error,
     %Error{
       code: "not_available_for_managed_client",
       message:
         "This call acts on your own organization and is not available on a managed " <>
           "client view. Use the client from EndPointBlank.Management.new/1."
     }}
  end

  defp encode_path(segments) do
    if Enum.all?(segments, &(is_binary(&1) and &1 != "")) do
      {:ok, "/api/v1" <> Enum.map_join(segments, &encode_segment/1)}
    else
      {:error, Error.invalid_request("Every id in the path must be a non-empty string.")}
    end
  end

  defp encode_segment(segment), do: "/" <> URI.encode(segment, &URI.char_unreserved?/1)

  defp request_options(client, method, path, opts) do
    headers =
      [
        {"authorization", "Bearer " <> client.key},
        {"accept", "application/json"},
        {"user-agent", user_agent()}
      ] ++ idempotency_header(opts[:idempotency_key])

    own =
      [
        method: method,
        url: client.base_url <> path,
        headers: headers,
        # This module retries, with the Idempotency-Key and the rules above.
        retry: false,
        receive_timeout: client.receive_timeout
      ] ++ json_option(opts[:json]) ++ params_option(opts[:params])

    Keyword.merge(client.req_options, own)
  end

  defp idempotency_header(nil), do: []
  defp idempotency_header(key), do: [{"idempotency-key", key}]

  defp json_option(nil), do: []
  defp json_option(body), do: [json: body]

  defp params_option(nil), do: []
  defp params_option([]), do: []
  defp params_option(params), do: [params: params]

  defp attempt(client, method, request_options, retries) do
    case send_request(request_options) do
      {:ok, body} ->
        {:ok, body}

      {:error, error} ->
        case retry_wait(client, method, error, retries) do
          {:retry, wait_ms} ->
            client.sleep.(wait_ms)
            attempt(client, method, request_options, retries + 1)

          :stop ->
            {:error, error}
        end
    end
  end

  defp send_request(request_options) do
    case Req.request(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{} = response} -> {:error, Error.from_response(response)}
      {:error, reason} -> {:error, Error.transport(reason)}
    end
  end

  defp retry_wait(%Management{max_retries: max_retries}, _method, _error, retries)
       when retries >= max_retries,
       do: :stop

  # Refused before it ran, so safe for every method, PATCH included.
  defp retry_wait(client, _method, %Error{status: 429, retry_after: seconds}, _retries) do
    wait_ms = (seconds || 1) * 1000

    if wait_ms <= client.max_retry_wait_ms, do: {:retry, wait_ms}, else: :stop
  end

  # The first request with this key is still running: ask again, same key.
  defp retry_wait(_client, :post, %Error{code: "idempotency_request_in_progress"}, retries),
    do: {:retry, backoff_ms(retries)}

  defp retry_wait(_client, method, %Error{status: status}, retries)
       when method in @retry_on_failure and is_integer(status) and status >= 500,
       do: {:retry, backoff_ms(retries)}

  defp retry_wait(_client, method, %Error{code: "transport_error"}, retries)
       when method in @retry_on_failure,
       do: {:retry, backoff_ms(retries)}

  defp retry_wait(_client, _method, _error, _retries), do: :stop

  defp backoff_ms(retries), do: 500 * Integer.pow(2, retries)

  defp idempotency_key(opts) do
    case Keyword.get(opts, :idempotency_key) do
      key when is_binary(key) and key != "" -> key
      _none -> uuid4()
    end
  end

  defp body(nil), do: {:ok, nil}
  defp body(attrs) when is_map(attrs), do: {:ok, attrs}

  defp body(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs)}
    else
      {:error, Error.invalid_request("Attributes must be a map or a keyword list.")}
    end
  end

  defp body(_attrs),
    do: {:error, Error.invalid_request("Attributes must be a map or a keyword list.")}

  defp list_params(opts, filters) do
    params =
      opts
      |> Keyword.take([:limit, :after | filters])
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)

    case Keyword.get(params, :limit) do
      nil ->
        {:ok, params}

      limit when is_integer(limit) and limit >= 1 and limit <= @max_limit ->
        {:ok, params}

      _other ->
        {:error, Error.invalid_request("limit must be an integer from 1 to #{@max_limit}.")}
    end
  end

  defp to_page(%{"data" => data} = body) when is_list(data),
    do: {:ok, %Page{data: data, next_cursor: Map.get(body, "next_cursor")}}

  defp to_page(_body), do: {:error, unexpected_body()}

  defp unexpected_body do
    %Error{
      code: "unexpected_response",
      message: "The management API answered without the expected data."
    }
  end
end
