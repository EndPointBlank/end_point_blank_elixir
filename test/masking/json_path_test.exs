defmodule EndPointBlank.Masking.JsonPathTest do
  @moduledoc """
  The path engine decides which nodes a masking rule reaches. A path that
  quietly matches nothing is the dangerous failure here: the rule appears
  configured in the portal and the data ships unmasked. So both halves are
  pinned — what each supported form selects, and that unsupported input is
  reported as `:error` rather than silently selecting nothing.

  The subset is shared with intake and the other client libraries.
  """
  use ExUnit.Case, async: true

  alias EndPointBlank.Masking.JsonPath

  # Parses and masks in one step, the way Masking uses this module.
  defp mask(value, path) do
    {:ok, tokens} = JsonPath.parse(path)
    JsonPath.transform(value, tokens, fn _old -> "***" end)
  end

  describe "selecting object keys" do
    test "$.name selects a top-level key" do
      assert mask(%{"a" => 1, "b" => 2}, "$.a") == %{"a" => "***", "b" => 2}
    end

    test "dots chain into nested objects" do
      assert mask(%{"user" => %{"ssn" => "123", "name" => "Ada"}}, "$.user.ssn") ==
               %{"user" => %{"ssn" => "***", "name" => "Ada"}}
    end

    test "single-quoted bracket form selects the same key" do
      assert mask(%{"a" => 1}, "$['a']") == %{"a" => "***"}
    end

    test "double-quoted bracket form selects the same key" do
      assert mask(%{"a" => 1}, "$[\"a\"]") == %{"a" => "***"}
    end

    test "the bracket form reaches keys the dot form cannot express" do
      # Header names contain hyphens, so without this no header could be masked
      # by path at all.
      assert mask(%{"x-api-key" => "secret"}, "$['x-api-key']") == %{"x-api-key" => "***"}
    end

    test "key matching is case-sensitive" do
      assert mask(%{"Token" => "secret"}, "$.token") == %{"Token" => "secret"}
    end
  end

  describe "selecting array elements" do
    test "[n] selects one element by position" do
      assert mask(%{"xs" => [1, 2, 3]}, "$.xs[1]") == %{"xs" => [1, "***", 3]}
    end

    test "[0] selects the first element" do
      assert mask([1, 2], "$[0]") == ["***", 2]
    end

    test "an index past the end changes nothing" do
      assert mask(%{"xs" => [1, 2]}, "$.xs[5]") == %{"xs" => [1, 2]}
    end
  end

  describe "wildcards" do
    test ".* selects every value of an object" do
      assert mask(%{"a" => 1, "b" => 2}, "$.*") == %{"a" => "***", "b" => "***"}
    end

    test "[*] selects every element of an array" do
      assert mask(%{"xs" => [1, 2]}, "$.xs[*]") == %{"xs" => ["***", "***"]}
    end

    test "a wildcard can be followed by more path" do
      # The usual shape for a collection response: mask one field of every item.
      value = %{"items" => [%{"id" => 1, "pin" => "111"}, %{"id" => 2, "pin" => "222"}]}

      assert mask(value, "$.items[*].pin") ==
               %{"items" => [%{"id" => 1, "pin" => "***"}, %{"id" => 2, "pin" => "***"}]}
    end
  end

  describe "recursive descent" do
    test "..name selects the key at the top level" do
      assert mask(%{"pin" => "1", "a" => 2}, "$..pin") == %{"pin" => "***", "a" => 2}
    end

    test "..name selects the key at any depth" do
      value = %{"a" => %{"pin" => "1", "b" => %{"pin" => "2"}}, "pin" => "3"}

      assert mask(value, "$..pin") == %{
               "a" => %{"pin" => "***", "b" => %{"pin" => "***"}},
               "pin" => "***"
             }
    end

    test "..name descends through arrays" do
      value = %{"users" => [%{"pin" => "1"}, %{"pin" => "2"}]}

      assert mask(value, "$..pin") == %{"users" => [%{"pin" => "***"}, %{"pin" => "***"}]}
    end

    test "..name can be followed by more path" do
      value = %{"outer" => %{"card" => %{"cvv" => "123", "last4" => "4242"}}}

      assert mask(value, "$..card.cvv") ==
               %{"outer" => %{"card" => %{"cvv" => "***", "last4" => "4242"}}}
    end
  end

  describe "the root path" do
    test "$ alone replaces the whole value" do
      assert mask(%{"a" => 1}, "$") == "***"
    end
  end

  describe "paths that select nothing" do
    test "a key that is not present leaves the object untouched" do
      assert mask(%{"a" => 1}, "$.missing") == %{"a" => 1}
    end

    test "a key path applied to a list leaves it untouched" do
      assert mask(%{"xs" => [1, 2]}, "$.xs.name") == %{"xs" => [1, 2]}
    end

    test "an index path applied to an object leaves it untouched" do
      assert mask(%{"a" => %{"b" => 1}}, "$.a[0]") == %{"a" => %{"b" => 1}}
    end

    test "a wildcard applied to a scalar leaves it untouched" do
      assert mask(%{"a" => "scalar"}, "$.a.*") == %{"a" => "scalar"}
    end

    test "descending into a scalar leaves it untouched" do
      assert mask("just a string", "$..pin") == "just a string"
    end
  end

  describe "input outside the supported subset" do
    test "a path not anchored at the root is rejected" do
      assert JsonPath.parse("user.ssn") == :error
    end

    test "an empty path is rejected" do
      assert JsonPath.parse("") == :error
    end

    test "a trailing dot with no name is rejected" do
      assert JsonPath.parse("$.") == :error
    end

    test "a recursive descent with no name is rejected" do
      assert JsonPath.parse("$..") == :error
    end

    test "an unterminated bracket is rejected" do
      assert JsonPath.parse("$[0") == :error
      assert JsonPath.parse("$['a") == :error
    end

    test "a negative index is rejected" do
      assert JsonPath.parse("$[-1]") == :error
    end

    test "a non-numeric bare bracket is rejected" do
      assert JsonPath.parse("$[abc]") == :error
    end

    test "filter expressions and slices are rejected rather than half-understood" do
      # Accepting a filter and ignoring the predicate would mask the wrong nodes,
      # which is worse than declining the rule.
      assert JsonPath.parse("$.items[?(@.id==1)]") == :error
      assert JsonPath.parse("$.items[0:2]") == :error
    end

    test "garbage after a valid prefix is rejected" do
      assert JsonPath.parse("$.a!!") == :error
    end

    test "rejects rather than raises on pathological input" do
      # Paths arrive from portal configuration and reach this parser unvalidated,
      # inside the request path of the host application.
      for input <- ["%%%", "$['unclosed", "$[\"unclosed", "$.ключ", String.duplicate("$", 500)] do
        assert JsonPath.parse(input) == :error
      end
    end
  end

  describe "transform/3 given no usable tokens" do
    test "leaves the value alone for :error" do
      assert JsonPath.transform(%{"a" => 1}, :error, fn _ -> "***" end) == %{"a" => 1}
    end

    test "leaves the value alone for nil" do
      assert JsonPath.transform(%{"a" => 1}, nil, fn _ -> "***" end) == %{"a" => 1}
    end
  end

  describe "immutability" do
    test "siblings and untouched branches survive unchanged" do
      value = %{"keep" => %{"deep" => [1, 2]}, "mask" => "secret"}

      assert mask(value, "$.mask") == %{"keep" => %{"deep" => [1, 2]}, "mask" => "***"}
    end
  end
end
