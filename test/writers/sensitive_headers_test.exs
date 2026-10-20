defmodule EndPointBlank.Writers.SensitiveHeadersTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.Writers

  test "names the credential, cookie, API key and token headers, lower-cased (sc-1470, sc-1626)" do
    assert Enum.sort(Writers.sensitive_headers()) ==
             Enum.sort([
               "authorization",
               "proxy-authorization",
               "cookie",
               "set-cookie",
               "x-api-key",
               "api-key",
               "x-auth-token",
               "x-access-token",
               "x-refresh-token",
               "x-amz-security-token",
               "x-csrf-token",
               "x-xsrf-token",
               "x-goog-api-key",
               "ocp-apim-subscription-key"
             ])
  end

  test "drops the API key and token headers whatever their case (sc-1626)" do
    headers = [
      {"X-Api-Key", "k1"},
      {"API-KEY", "k2"},
      {"x-auth-token", "t1"},
      {"X-Access-Token", "t2"},
      {"X-Amz-Security-Token", "t3"},
      {"Ocp-Apim-Subscription-Key", "k3"},
      {"x-api-version", "kept"}
    ]

    assert Writers.reportable_headers(headers) == %{"x-api-version" => "kept"}
  end

  test "drops every listed header whatever its case and keeps the rest" do
    headers = [
      {"Authorization", "Basic x"},
      {"PROXY-AUTHORIZATION", "Basic y"},
      {"cookie", "a=b"},
      {"Set-Cookie", "c=d"},
      {"x-authorization-hint", "kept"},
      {"accept", "application/json"}
    ]

    assert Writers.reportable_headers(headers) == %{
             "x-authorization-hint" => "kept",
             "accept" => "application/json"
           }
  end

  test "keeps a header whose name is not a binary rather than raising" do
    assert Writers.reportable_headers([{:authorization, "x"}]) == %{authorization: "x"}
  end

  test "answers an empty map for no headers" do
    assert Writers.reportable_headers([]) == %{}
  end
end
