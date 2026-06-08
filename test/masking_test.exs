defmodule EndPointBlank.MaskingTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.Masking

  # New rule shape: single :target, optional :path, optional :regex, :replacement_value.
  defp rule(target, opts \\ []) do
    %{
      target: target,
      path: Keyword.get(opts, :path),
      regex: Keyword.get(opts, :regex),
      replacement_value: Keyword.get(opts, :replacement_value, "...")
    }
  end

  describe "reference vectors" do
    test "path only: $.user.ssn" do
      payload = %{request: ~s({"user":{"ssn":"abc"}})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "$.user.ssn", replacement_value: "***")],
          nil
        )

      assert Jason.decode!(out.request) == %{"user" => %{"ssn" => "***"}}
    end

    test "path only recursive descent: $..password" do
      payload = %{request: ~s({"a":{"password":1},"b":{"password":2}})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "$..password", replacement_value: "***")],
          nil
        )

      assert Jason.decode!(out.request) == %{
               "a" => %{"password" => "***"},
               "b" => %{"password" => "***"}
             }
    end

    test "path + regex: $.note with SSN regex" do
      payload = %{request: ~s({"note":"ssn 123-45-6789"})}

      r =
        rule("request_body",
          path: "$.note",
          regex: "\\d{3}-\\d{2}-\\d{4}",
          replacement_value: "XXX"
        )

      out = Masking.apply(payload, :request, [r], nil)
      assert Jason.decode!(out.request) == %{"note" => "ssn XXX"}
    end

    test "regex only: only string leaves matching are substituted" do
      payload = %{request: ~s({"a":"x 123-45-6789","b":"y"})}
      r = rule("request_body", regex: "\\d{3}-\\d{2}-\\d{4}", replacement_value: "XXX")
      out = Masking.apply(payload, :request, [r], nil)
      assert Jason.decode!(out.request) == %{"a" => "x XXX", "b" => "y"}
    end

    test "path with wildcard over a list: $.list[*].k" do
      payload = %{request: ~s({"list":[{"k":"p"},{"k":"q"}]})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "$.list[*].k", replacement_value: "_")],
          nil
        )

      assert Jason.decode!(out.request) == %{"list" => [%{"k" => "_"}, %{"k" => "_"}]}
    end

    test "path no-ops on a non-JSON plain string target" do
      payload = %{path: "123-45-6789"}

      out =
        Masking.apply(payload, :request, [rule("path", path: "$.x", replacement_value: "_")], nil)

      assert out.path == "123-45-6789"
    end
  end

  describe "headers (map target)" do
    test "path selects a header key and replaces it" do
      payload = %{headers: %{"Authorization" => "Bearer x", "X-Trace" => "ok"}}

      out =
        Masking.apply(payload, :request, [rule("request_headers", path: "$.Authorization")], nil)

      assert out.headers == %{"Authorization" => "...", "X-Trace" => "ok"}
    end

    test "regex applies to every string header value" do
      payload = %{headers: %{"Authorization" => "Bearer abc123", "X-Trace" => "ok"}}
      r = rule("request_headers", regex: "abc\\d+", replacement_value: "[redacted]")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.headers == %{"Authorization" => "Bearer [redacted]", "X-Trace" => "ok"}
    end
  end

  describe "targets and record types" do
    test "regex-masks the URL path (plain string)" do
      payload = %{path: "/users/a@b.com/x"}
      r = rule("path", regex: "[\\w.]+@[\\w.]+", replacement_value: "...")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "/users/.../x"
    end

    test "masks a response body (wire key :body)" do
      payload = %{body: ~s({"email":"a@b.com"})}
      out = Masking.apply(payload, :response, [rule("response_body", path: "$.email")], nil)
      assert Jason.decode!(out.body) == %{"email" => "..."}
    end

    test "masks an error message via regex (wire key :message)" do
      payload = %{message: "failed for a@b.com here"}
      r = rule("error_message", regex: "[\\w.]+@[\\w.]+", replacement_value: "...")
      out = Masking.apply(payload, :error, [r], nil)
      assert out.message == "failed for ... here"
    end

    test "does not touch request fields for an error record" do
      payload = %{request: ~s({"email":"a@b.com"})}
      out = Masking.apply(payload, :error, [rule("request_body", path: "$.email")], nil)
      assert out.request == ~s({"email":"a@b.com"})
    end
  end

  describe "graceful degradation" do
    test "non-JSON body: path no-ops, regex still applies to raw string" do
      payload = %{request: "not json a@b.com"}

      r =
        rule("request_body", path: "$.email", regex: "[\\w.]+@[\\w.]+", replacement_value: "...")

      out = Masking.apply(payload, :request, [r], nil)
      assert out.request == "not json ..."
    end

    test "bad regex degrades to no-op" do
      payload = %{path: "/users/x"}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("path", regex: "([unterminated", replacement_value: "_")],
          nil
        )

      assert out.path == "/users/x"
    end

    test "malformed path degrades to no-op" do
      payload = %{request: ~s({"a":"b"})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "not a path", replacement_value: "_")],
          nil
        )

      assert Jason.decode!(out.request) == %{"a" => "b"}
    end

    test "neither path nor regex is a no-op" do
      payload = %{request: ~s({"a":"b"})}
      out = Masking.apply(payload, :request, [rule("request_body")], nil)
      assert Jason.decode!(out.request) == %{"a" => "b"}
    end

    test "blank replacement_value coerces to ..." do
      payload = %{request: ~s({"a":"b"})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "$.a", replacement_value: "")],
          nil
        )

      assert Jason.decode!(out.request) == %{"a" => "..."}
    end
  end

  describe "replacement backreferences (regex substitutions)" do
    test "path + regex: card number with $1-****-****-$2" do
      payload = %{request: ~s({"card":"4111-1111-1111-1234"})}

      r =
        rule("request_body",
          path: "$.card",
          regex: "(\\d{4})-\\d{4}-\\d{4}-(\\d{4})",
          replacement_value: "$1-****-****-$2"
        )

      out = Masking.apply(payload, :request, [r], nil)
      assert Jason.decode!(out.request) == %{"card" => "4111-****-****-1234"}
    end

    test "regex only: $1-XX-XXXX on an SSN" do
      payload = %{path: "123-45-6789"}

      r =
        rule("path",
          regex: "(\\d{3})-(\\d{2})-(\\d{4})",
          replacement_value: "$1-XX-XXXX"
        )

      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "123-XX-XXXX"
    end

    test "regex only: global multi-match with [$1]" do
      payload = %{path: "ab1c2"}
      r = rule("path", regex: "(\\d)", replacement_value: "[$1]")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "ab[1]c[2]"
    end

    test "regex only: swap groups $2/$1" do
      payload = %{path: "12-34"}
      r = rule("path", regex: "(\\d+)-(\\d+)", replacement_value: "$2/$1")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "34/12"
    end

    test "no-group regex with $1 expands to empty string" do
      payload = %{path: "42"}
      r = rule("path", regex: "(\\d+)", replacement_value: "$3")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == ""
    end

    test "$$ expands to a literal dollar" do
      payload = %{path: "5"}
      r = rule("path", regex: "\\d", replacement_value: "$$")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "$"
    end

    test "$0 expands to the whole match" do
      payload = %{path: "abc"}
      r = rule("path", regex: "b", replacement_value: "[$0]")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "a[b]c"
    end

    test "lone $ not followed by digit/$ is literal" do
      payload = %{path: "x"}
      r = rule("path", regex: "x", replacement_value: "a$b")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "a$b"
    end

    test "trailing $ is literal" do
      payload = %{path: "x"}
      r = rule("path", regex: "x", replacement_value: "a$")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "a$"
    end

    test "multi-digit group number $12 reads the full run" do
      payload = %{path: "abcdefghijklm"}
      # 12 single-char capture groups, then group 12 is "l"
      re =
        "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)"

      r = rule("path", regex: re, replacement_value: "<$12>")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "<l>m"
    end

    test "path-only replacement stays literal (no expansion)" do
      payload = %{request: ~s({"a":"b"})}

      out =
        Masking.apply(
          payload,
          :request,
          [rule("request_body", path: "$.a", replacement_value: "$1$$")],
          nil
        )

      assert Jason.decode!(out.request) == %{"a" => "$1$$"}
    end

    test "non-participating group expands to empty string" do
      payload = %{path: "ac"}
      r = rule("path", regex: "a(x)?c", replacement_value: "[$1]")
      out = Masking.apply(payload, :request, [r], nil)
      assert out.path == "[]"
    end
  end

  describe "hook" do
    test "runs the hook after the rules" do
      payload = %{request: ~s({"email":"a@b.com"})}
      hook = fn p, _type -> Map.put(p, :extra, "added") end
      out = Masking.apply(payload, :request, [rule("request_body", path: "$.email")], hook)
      assert out.extra == "added"
      assert Jason.decode!(out.request) == %{"email" => "..."}
    end

    test "applies with no rules and no hook" do
      payload = %{request: ~s({"a":"b"})}
      assert Masking.apply(payload, :request, nil, nil) == payload
    end
  end
end
