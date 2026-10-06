defmodule EndPointBlank.Writers.SensitiveHeadersTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.Writers

  test "names the credential and cookie headers, lower-cased (sc-1470)" do
    assert Enum.sort(Writers.sensitive_headers()) ==
             ["authorization", "cookie", "proxy-authorization", "set-cookie"]
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
