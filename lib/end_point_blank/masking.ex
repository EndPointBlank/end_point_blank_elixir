defmodule EndPointBlank.Masking do
  @moduledoc """
  Client-side masking. Applies configured rules to an outgoing payload's
  maskable fields for the record_type, then runs the optional user hook.

  Payload keys are ATOMS matching the writers' payloads / intake wire keys.

  Each rule is a map (atom-keyed) with:

    * `:target` — one of `"request_body"`, `"request_headers"`, `"path"`,
      `"response_body"`, `"error_message"`; mapped to a wire key per `@field_map`.
    * `:path` — a JSONPath string (or nil/""): selects node(s) to mask.
    * `:regex` — a regex string (or nil/""): substitutes within string leaves.
    * `:replacement_value` — literal replacement string (blank ⇒ "...").

  Matching semantics ("path scopes, regex matches within"):

    * path only    — replace each node selected by the path entirely.
    * regex only   — global regex substitution on every string leaf.
    * path + regex — within each selected node, regex-substitute string leaves.

  Bad regex or unparseable path make the rule a no-op. For non-JSON body values,
  `:path` no-ops and `:regex` (if valid) applies to the raw string; never raise.
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
      re -> regex_replace_all(re, value, replacement(rule))
    end
  end

  # Applies the rule to a structured value (decoded JSON or header map).
  defp apply_to_value(value, rule) do
    tokens = parse_path(rule)
    regex_str = Map.get(rule, :regex)
    re = compile_regex(rule)
    repl = replacement(rule)

    path_invalid? = tokens == :error
    regex_invalid? = is_binary(regex_str) and regex_str != "" and is_nil(re)

    if path_invalid? or regex_invalid? do
      value
    else
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
  end

  defp usable_path?(tokens) when is_list(tokens), do: true
  defp usable_path?(_), do: false

  # Recurse over containers; substitute on every string leaf.
  defp regex_replace_leaves(node, re, repl) when is_binary(node) do
    regex_replace_all(re, node, repl)
  end

  defp regex_replace_leaves(node, re, repl) when is_map(node) do
    Map.new(node, fn {k, v} -> {k, regex_replace_leaves(v, re, repl)} end)
  end

  defp regex_replace_leaves(node, re, repl) when is_list(node) do
    Enum.map(node, &regex_replace_leaves(&1, re, repl))
  end

  defp regex_replace_leaves(node, _re, _repl), do: node

  # Global regex substitution where `template` is a backreference template:
  # `$N` inserts capture group N (`$0` = whole match), `$$` = literal `$`. See
  # the shared "Replacement Backreferences" contract. Uses `:index` scan so the
  # match list is finite (no infinite loop), and never raises.
  @doc false
  def regex_replace_all(re, string, template) when is_binary(string) do
    matches = Regex.scan(re, string, return: :index)

    {out, cursor} =
      Enum.reduce(matches, {[], 0}, fn match, {acc, cursor} ->
        [{start, len} | _] = match
        prefix = binary_part(string, cursor, start - cursor)
        groups = Enum.map(match, fn {s, l} -> substring(string, s, l) end)
        next_cursor = min(start + max(len, 1), byte_size(string))
        {[expand(template, groups), prefix | acc], next_cursor}
      end)

    rest = binary_part(string, cursor, byte_size(string) - cursor)
    IO.iodata_to_binary(Enum.reverse([rest | out]))
  end

  # Non-participating group = {-1, 0} → "".
  defp substring(_string, start, _len) when start < 0, do: ""
  defp substring(string, start, len), do: binary_part(string, start, len)

  # Expand `$`-tokens in `template` against `groups` (0-indexed: groups[0] is the
  # whole match). Implemented explicitly per spec — does NOT use Elixir's native
  # `\N` replacement syntax.
  @doc false
  def expand(template, groups) do
    do_expand(template, groups, [])
  end

  defp do_expand(<<>>, _groups, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp do_expand(<<"$$", rest::binary>>, groups, acc) do
    do_expand(rest, groups, ["$" | acc])
  end

  defp do_expand(<<"$", rest::binary>>, groups, acc) do
    case take_digits(rest, []) do
      {nil, _rest} ->
        # `$` followed by a non-digit (and not `$`), or trailing `$`: literal `$`.
        do_expand(rest, groups, ["$" | acc])

      {n, after_digits} ->
        do_expand(after_digits, groups, [group_at(groups, n) | acc])
    end
  end

  defp do_expand(<<c::utf8, rest::binary>>, groups, acc) do
    do_expand(rest, groups, [<<c::utf8>> | acc])
  end

  # Read the full consecutive digit run as an integer. Returns {nil, rest} when
  # there is no leading digit.
  defp take_digits(<<d, rest::binary>>, acc) when d in ?0..?9 do
    take_digits(rest, [d | acc])
  end

  defp take_digits(rest, []), do: {nil, rest}

  defp take_digits(rest, acc) do
    n = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer()
    {n, rest}
  end

  defp group_at(groups, n), do: Enum.at(groups, n, "")

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
