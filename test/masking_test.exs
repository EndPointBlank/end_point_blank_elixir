defmodule EndPointBlank.MaskingTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.Masking

  defp key_rule(v, targets, mask \\ "..."), do: %{match_type: "key", match_value: v, targets: targets, mask_value: mask}
  defp regex_rule(s, targets, mask \\ "..."), do: %{match_type: "regex", match_value: s, targets: targets, mask_value: mask}

  test "masks a matching header value case-insensitively" do
    payload = %{headers: %{"Authorization" => "Bearer x", "X-Trace" => "ok"}}
    out = Masking.apply(payload, :request, [key_rule("authorization", ["request_headers"])], nil)
    assert out.headers == %{"Authorization" => "...", "X-Trace" => "ok"}
  end

  test "masks matching keys in a JSON request body" do
    payload = %{request: ~s({"user":{"email":"a@b.com"}})}
    out = Masking.apply(payload, :request, [key_rule("email", ["request_body"], "[X]")], nil)
    assert Jason.decode!(out.request) == %{"user" => %{"email" => "[X]"}}
  end

  test "leaves a non-JSON body unchanged for a key rule" do
    payload = %{request: "not json a@b.com"}
    out = Masking.apply(payload, :request, [key_rule("email", ["request_body"])], nil)
    assert out.request == "not json a@b.com"
  end

  test "regex-masks the path substring" do
    payload = %{path: "/users/a@b.com/x"}
    out = Masking.apply(payload, :request, [regex_rule("[\\w.]+@[\\w.]+", ["path"])], nil)
    assert out.path == "/users/.../x"
  end

  test "masks a response body (wire key :body)" do
    payload = %{body: ~s({"email":"a@b.com"})}
    out = Masking.apply(payload, :response, [key_rule("email", ["response_body"])], nil)
    assert Jason.decode!(out.body) == %{"email" => "..."}
  end

  test "does not touch request fields for an error record" do
    payload = %{request: ~s({"email":"a@b.com"})}
    out = Masking.apply(payload, :error, [key_rule("email", ["request_body"])], nil)
    assert out.request == ~s({"email":"a@b.com"})
  end

  test "runs the hook after the rules" do
    payload = %{request: ~s({"email":"a@b.com"})}
    hook = fn p, _type -> Map.put(p, :extra, "added") end
    out = Masking.apply(payload, :request, [key_rule("email", ["request_body"])], hook)
    assert out.extra == "added"
    assert Jason.decode!(out.request) == %{"email" => "..."}
  end
end
