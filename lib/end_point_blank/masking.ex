defmodule EndPointBlank.Masking do
  @moduledoc """
  Client-side masking. Applies configured rules to an outgoing payload's
  maskable fields for the record_type, then runs the optional user hook.

  Payload keys are ATOMS matching the writers' payloads / intake wire keys.
  """

  @field_map %{
    request: %{"request_body" => :request, "request_headers" => :headers, "path" => :path},
    response: %{"response_body" => :body},
    error: %{"error_message" => :message},
    log: %{}
  }

  def apply(payload, record_type, rules, hook) do
    masked = Enum.reduce(rules || [], payload, &apply_rule(&2, record_type, &1))
    run_hook(masked, record_type, hook)
  end

  defp run_hook(payload, _type, nil), do: payload
  defp run_hook(payload, type, hook) when is_function(hook, 2), do: hook.(payload, Atom.to_string(type))
  defp run_hook(payload, _type, _hook), do: payload

  defp apply_rule(payload, record_type, rule) do
    field_map = Map.get(@field_map, record_type, %{})

    Enum.reduce(rule.targets, payload, fn target, acc ->
      case Map.fetch(field_map, target) do
        {:ok, key} -> maybe_mask(acc, key, rule)
        :error -> acc
      end
    end)
  end

  defp maybe_mask(payload, key, rule) do
    case Map.get(payload, key) do
      nil -> payload
      value -> Map.put(payload, key, mask_value(value, rule))
    end
  end

  defp mask_value(value, rule) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, mask_header(k, v, rule)} end)
  end

  defp mask_value(value, rule) when is_binary(value), do: mask_string(value, rule)
  defp mask_value(value, _rule), do: value

  defp mask_header(k, v, %{match_type: "key", match_value: mv, mask_value: mask}) do
    if is_binary(k) and String.downcase(k) == String.downcase(mv), do: mask, else: v
  end

  defp mask_header(_k, v, %{match_type: "regex", match_value: mv, mask_value: mask}) when is_binary(v) do
    Regex.replace(Regex.compile!(mv), v, mask)
  end

  defp mask_header(_k, v, _rule), do: v

  defp mask_string(value, %{match_type: "regex", match_value: mv, mask_value: mask}) do
    Regex.replace(Regex.compile!(mv), value, mask)
  end

  defp mask_string(value, %{match_type: "key", match_value: mv, mask_value: mask}) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded |> mask_json(mv, mask) |> Jason.encode!()
      {:error, _} -> value
    end
  end

  defp mask_json(data, mv, mask) when is_map(data) do
    Map.new(data, fn {k, v} ->
      if String.downcase(to_string(k)) == String.downcase(mv), do: {k, mask}, else: {k, mask_json(v, mv, mask)}
    end)
  end

  defp mask_json(data, mv, mask) when is_list(data), do: Enum.map(data, &mask_json(&1, mv, mask))
  defp mask_json(data, _mv, _mask), do: data
end
