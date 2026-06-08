defmodule EndPointBlank.Masking.JsonPath do
  @moduledoc """
  A constrained, well-defined JSONPath subset shared across intake and the
  client libraries. It parses a path string into tokens and transforms a value
  by replacing every fully-matched location with the result of a callback,
  rebuilding parent containers immutably.

  Supported tokens:

    * `$`              — root.
    * `.name` / `['name']` / `["name"]` — `{:child, name}` (object key, case-sensitive).
    * `[n]`            — `{:index, n}` (0-based array index).
    * `.*` / `[*]`     — `:wildcard` (every object value / array element).
    * `..name`         — `{:descendant, name}` (every value under key `name` at any depth).

  Anything outside this subset (filters, slices, unions, garbled input) makes
  `parse/1` return `:error`; callers treat that as "matches nothing". Functions
  here never raise.
  """

  @type token ::
          {:child, String.t()}
          | {:index, non_neg_integer()}
          | :wildcard
          | {:descendant, String.t()}
  @type tokens :: [token()]

  @doc """
  Parses a JSONPath string into a token list. Returns `{:ok, tokens}` or
  `:error` for unsupported/garbled input. Never raises.
  """
  @spec parse(String.t()) :: {:ok, tokens()} | :error
  def parse("$" <> rest), do: parse_tokens(rest, [])
  def parse(_), do: :error

  # End of input — done.
  defp parse_tokens("", acc), do: {:ok, Enum.reverse(acc)}

  # Recursive descent: `..name`
  defp parse_tokens(".." <> rest, acc) do
    case take_name(rest) do
      {name, remaining} when name != "" -> parse_tokens(remaining, [{:descendant, name} | acc])
      _ -> :error
    end
  end

  # Dot wildcard: `.*`
  defp parse_tokens(".*" <> rest, acc), do: parse_tokens(rest, [:wildcard | acc])

  # Dot child: `.name`
  defp parse_tokens("." <> rest, acc) do
    case take_name(rest) do
      {name, remaining} when name != "" -> parse_tokens(remaining, [{:child, name} | acc])
      _ -> :error
    end
  end

  # Bracket forms: `[*]`, `[n]`, `['name']`, `["name"]`
  defp parse_tokens("[" <> rest, acc) do
    case parse_bracket(rest) do
      {token, remaining} -> parse_tokens(remaining, [token | acc])
      :error -> :error
    end
  end

  defp parse_tokens(_other, _acc), do: :error

  # Wildcard inside brackets.
  defp parse_bracket("*]" <> rest), do: {:wildcard, rest}

  # Quoted child names (single or double quotes); any chars between quotes.
  defp parse_bracket("'" <> rest), do: parse_quoted(rest, "'")
  defp parse_bracket("\"" <> rest), do: parse_quoted(rest, "\"")

  # Numeric index.
  defp parse_bracket(rest) do
    case Integer.parse(rest) do
      {n, "]" <> remaining} when n >= 0 -> {{:index, n}, remaining}
      _ -> :error
    end
  end

  defp parse_quoted(rest, quote_char) do
    case String.split(rest, quote_char <> "]", parts: 2) do
      [name, remaining] -> {{:child, name}, remaining}
      _ -> :error
    end
  end

  # Consumes a leading [A-Za-z0-9_]+ run, returning {name, remaining}.
  defp take_name(string), do: take_name(string, "")

  defp take_name(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    take_name(rest, <<acc::binary, c>>)
  end

  defp take_name(rest, acc), do: {acc, rest}

  @doc """
  Walks `value` following `tokens`, replacing each fully-matched location with
  `fun.(old_value)` and rebuilding parents immutably. Unmatched locations are
  left unchanged. Never raises.
  """
  @spec transform(any(), tokens() | nil | :error, (any() -> any())) :: any()
  def transform(value, :error, _fun), do: value
  def transform(value, nil, _fun), do: value
  def transform(value, [], fun), do: fun.(value)

  def transform(value, [{:child, key} | rest], fun) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, child} -> Map.put(value, key, transform(child, rest, fun))
      :error -> value
    end
  end

  def transform(value, [{:child, _key} | _rest], _fun), do: value

  def transform(value, [{:index, i} | rest], fun) when is_list(value) do
    if i >= 0 and i < length(value) do
      List.update_at(value, i, &transform(&1, rest, fun))
    else
      value
    end
  end

  def transform(value, [{:index, _i} | _rest], _fun), do: value

  def transform(value, [:wildcard | rest], fun) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, transform(v, rest, fun)} end)
  end

  def transform(value, [:wildcard | rest], fun) when is_list(value) do
    Enum.map(value, &transform(&1, rest, fun))
  end

  def transform(value, [:wildcard | _rest], _fun), do: value

  def transform(value, [{:descendant, key} | rest], fun) do
    descend(value, key, rest, fun)
  end

  # Recursive descent: at this node and every nested node, any entry whose key
  # is `key` matches the remaining tokens.
  defp descend(value, key, rest, fun) when is_map(value) do
    Map.new(value, fn {k, v} ->
      v = descend(v, key, rest, fun)

      if k == key do
        {k, transform(v, rest, fun)}
      else
        {k, v}
      end
    end)
  end

  defp descend(value, key, rest, fun) when is_list(value) do
    Enum.map(value, &descend(&1, key, rest, fun))
  end

  defp descend(value, _key, _rest, _fun), do: value
end
