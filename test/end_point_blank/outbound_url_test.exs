defmodule EndPointBlank.OutboundUrlTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.OutboundUrl

  test "keeps scheme, host, port and path, and drops userinfo, query and fragment" do
    assert OutboundUrl.strip("https://user:hunter2@api.test:8443/v1/things?key=s3cret#frag") ==
             {:ok, "https://api.test:8443/v1/things"}
  end

  test "drops an empty query or fragment too" do
    assert OutboundUrl.strip("https://api.test/orders?") == {:ok, "https://api.test/orders"}
    assert OutboundUrl.strip("https://api.test/orders#") == {:ok, "https://api.test/orders"}
  end

  test "keeps the path exactly as written" do
    assert OutboundUrl.strip("https://api.test:8443/Orders/%2F/") ==
             {:ok, "https://api.test:8443/Orders/%2F/"}

    assert OutboundUrl.strip("https://api.test") == {:ok, "https://api.test"}
  end

  test "omits the scheme's default port" do
    assert OutboundUrl.strip("https://api.test:443/orders") == {:ok, "https://api.test/orders"}
    assert OutboundUrl.strip("http://api.test:80/orders") == {:ok, "http://api.test/orders"}
    assert OutboundUrl.strip("http://api.test:443/orders") == {:ok, "http://api.test:443/orders"}
  end

  test "drops an empty port, as the default it means" do
    assert OutboundUrl.strip("https://api.test:/orders") == {:ok, "https://api.test/orders"}
    assert OutboundUrl.strip("http://api.test:/orders") == {:ok, "http://api.test/orders"}
  end

  test "lowercases the scheme and host, but not the path" do
    assert OutboundUrl.strip("HTTPS://API.Example.TEST:443/Orders") ==
             {:ok, "https://api.example.test/Orders"}

    assert OutboundUrl.strip("HTTP://[FE80::1]:8080/x") == {:ok, "http://[fe80::1]:8080/x"}
  end

  test "refuses a port that is not a number from 1 to 65535" do
    for bad <- [
          "https://api.test:abc/orders",
          "https://api.test:0/orders",
          "https://api.test:65536/orders",
          "http://api.test:99999/orders"
        ] do
      assert OutboundUrl.strip(bad) == {:error, :invalid_base_url}
    end

    assert OutboundUrl.strip("https://api.test:1/orders") == {:ok, "https://api.test:1/orders"}

    assert OutboundUrl.strip("https://api.test:65535/orders") ==
             {:ok, "https://api.test:65535/orders"}
  end

  test "refuses any scheme other than http and https" do
    for bad <- [
          "ftp://files.test:21/x",
          "ws://api.test/socket",
          "wss://api.test/socket",
          "file:///etc/passwd",
          "custom://api.test/orders"
        ] do
      assert OutboundUrl.strip(bad) == {:error, :invalid_base_url}
    end
  end

  test "keeps an IPv6 host in brackets" do
    assert OutboundUrl.strip("http://[::1]:4001/orders?x=1") == {:ok, "http://[::1]:4001/orders"}
  end

  test "refuses anything without a scheme and host" do
    for bad <- [
          "not a url ?token=s3cret",
          "/orders",
          "https://",
          "mailto:a@b.test",
          "",
          nil,
          42
        ] do
      assert OutboundUrl.strip(bad) == {:error, :invalid_base_url}
    end
  end
end
