defmodule EndPointBlank.Masking do
  @moduledoc """
  Client-side masking. Applies configured rules to an outgoing payload's
  maskable fields for the record_type, then runs the optional user hook.

  Payload keys are ATOMS matching the writers' payloads / intake wire keys.

  Each rule is a map (atom-keyed) with:

    * `:target` — one of `request_body`, `request_headers`, `path`,
      `response_body`, `error_message`; mapped to a wire key per `@field_map`.
    * `:path` — a JSONPath string (or nil/""): selects node(s) to mask.
    * `:regex` — a regex string (or nil/""): substitutes within string leaves.
    * `:replacement_value` — literal replacement string (blank ⇒ "...").

  Matching semantics ("path scopes, regex matches within"):

    * path only    — replace each node selected by the path entirely.
    * regex only   — global regex substitution on every string leaf.
    * path + regex — within each selected node, regex-substitute string leaves.

  Bad regex / unparseable path / non-JSON body degrade to a no-op; never raise.
  """

  alias EndPointBlank.Masking.JsonPath

  @field_map %{
    request: %{"request_body" => :request, "request_headers" => :headers, "path" => :path},
    response: %{"response_body" => :body},
    error: %{"error_message" => :message},
    log: %{}
  }

  # Targets whose wire value is a JSON string body (decode/apply/re-encode).
  @json_targets ~w(request_body response_body)

  def apply(payload, record_type, rules, hook) do
    masked = Enum.reduce(rules || [], payload, &apply_rule(&2, record_type, &1))
    run_hook(masked, record_type, hook)
  end

  defp run_hook(payload, _type, nil), do: payload

  defp run_hook(payload, type, hook) when is_function(hook, 2),
    do: hook.(payload, Atom.to_string(type))

  defp run_hook(payload, _type, _hook), do: payload

  defp apply_rule(payload, record_type, rule) do
    field_map = Map.get(@field_map, record_type, %{})
    target = Map.get(rule, :target)

    case Map.fetch(field_map, target) do
      {:ok, key} ->
        case Map.fetch(payload, key) do
          {:ok, value} when not is_nil(value) ->
            Map.put(payload, key, mask_field(value, rule))

          _ ->
            payload
        end

      :error ->
        payload
    end
  end

  # Body targets: JSON string. Decode, apply on the decoded value, re-encode.
  # On non-JSON (or non-body string target): path no-ops; regex applies to raw.
  defp mask_field(value, rule) when is_binary(value) do
    if Map.get(rule, :target) in @json_targets do
      case Jason.decode(value) do
        {:ok, decoded} -> decoded |> apply_to_value(rule) |> Jason.encode!()
        {:error, _} -> apply_to_raw_string(value, rule)
      end
    else
      # path / error_message: plain strings — path no-ops, only regex applies.
      apply_to_raw_string(value, rule)
    end
  end

  # request_headers: a map. Path applies to the map; regex applies to string leaves.
  defp mask_field(value, rule) when is_map(value), do: apply_to_value(value, rule)

  defp mask_field(value, _rule), do: value

  # A plain, non-JSON string target: path cannot apply (no-op); regex applies.
  defp apply_to_raw_string(value, rule) do
    case compile_regex(rule) do
      nil -> value
      re -> Regex.replace(re, value, replacement(rule))
    end
  end

  # Applies the rule to a structured value (decoded JSON or header map).
  defp apply_to_value(value, rule) do
    tokens = parse_path(rule)
    re = compile_regex(rule)
    repl = replacement(rule)

    cond do
      # path + regex: select nodes, apply regex to leaves within each.
      usable_path?(tokens) and not is_nil(re) ->
        JsonPath.transform(value, tokens, &regex_replace_leaves(&1, re, repl))

      # path only: replace each selected node entirely.
      usable_path?(tokens) ->
        JsonPath.transform(value, tokens, fn _old -> repl end)

      # regex only: substitute across every string leaf.
      not is_nil(re) ->
        regex_replace_leaves(value, re, repl)

      # no usable path or regex: no-op.
      true ->
        value
    end
  end

  defp usable_path?(tokens) when is_list(tokens), do: true
  defp usable_path?(_), do: false

  # Recurse over containers; substitute on every string leaf.
  defp regex_replace_leaves(node, re, repl) when is_binary(node) do
    Regex.replace(re, node, repl)
  end

  defp regex_replace_leaves(node, re, repl) when is_map(node) do
    Map.new(node, fn {k, v} -> {k, regex_replace_leaves(v, re, repl)} end)
  end

  defp regex_replace_leaves(node, re, repl) when is_list(node) do
    Enum.map(node, &regex_replace_leaves(&1, re, repl))
  end

  defp regex_replace_leaves(node, _re, _repl), do: node

  # nil/blank path ⇒ nil (no path step). Parseable path ⇒ tokens. Bad ⇒ :error (no-op).
  defp parse_path(rule) do
    case Map.get(rule, :path) do
      p when is_binary(p) and p != "" ->
        case JsonPath.parse(p) do
          {:ok, tokens} -> tokens
          :error -> :error
        end

      _ ->
        nil
    end
  end

  # nil/blank regex ⇒ nil. Uncompilable regex ⇒ nil (no-op).
  defp compile_regex(rule) do
    case Map.get(rule, :regex) do
      s when is_binary(s) and s != "" ->
        case Regex.compile(s) do
          {:ok, re} -> re
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp replacement(rule) do
    case Map.get(rule, :replacement_value) do
      v when is_binary(v) and v != "" -> v
      _ -> "..."
    end
  end
end
