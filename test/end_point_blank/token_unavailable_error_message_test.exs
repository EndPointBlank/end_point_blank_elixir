defmodule EndPointBlank.TokenUnavailableErrorMessageTest do
  # The message is what reaches logs and error reporting, and the caller
  # controls the URL in it, so it must never repeat the URL's userinfo, query
  # or fragment (sc-1469 review on js#54). Error reporters capture an
  # exception's fields too, so neither may :base_url.
  use ExUnit.Case, async: true

  alias EndPointBlank.TokenUnavailableError

  @raw "https://user:hunter2@api.provider.test:8443/v1/things?api_key=s3cret#frag"
  @stripped "https://api.provider.test:8443/v1/things"

  @url "https://api.test/orders"
  @prefix "Could not mint an EndPointBlank access token for https://api.test/orders: "
  @suffix ". EndPointBlank never sends this service's client_id/client_secret to a " <>
            "provider, so there is no Basic-auth fallback and the call must not be " <>
            "made without a token."
  @transport "intake could not be reached (timeout, connection refused or " <>
               "retries exhausted); this may be transient"

  test "the message names only scheme, host, port and path" do
    message = Exception.message(TokenUnavailableError.exception(base_url: @raw))

    assert message =~ "for #{@stripped}: "

    for secret <- ~w(user hunter2 api_key s3cret frag) do
      refute message =~ secret
    end
  end

  test ":base_url holds the stripped URL, not the raw one" do
    assert TokenUnavailableError.exception(base_url: @raw).base_url == @stripped
  end

  test "an unparseable URL is left out of the message and off the exception" do
    message = TokenUnavailableError.message("not a url ?token=s3cret", nil)

    refute message =~ "s3cret"
    assert message =~ "could not be parsed"

    assert TokenUnavailableError.exception(base_url: "not a url ?token=s3cret").base_url == nil
  end

  # The same words in every EndPointBlank SDK (sc-1469 review, C2), so each
  # one is pinned exactly.
  describe "words each outcome exactly" do
    test "credential_rejected" do
      assert TokenUnavailableError.message(@url, :credential_rejected) ==
               @prefix <>
                 "intake rejected this application's client credential (HTTP 401); " <>
                 "retrying cannot help -- re-issue the credential" <>
                 @suffix
    end

    test "request_rejected" do
      assert TokenUnavailableError.message(@url, {:request_rejected, 422}) ==
               @prefix <>
                 "intake refused the token request (HTTP 422); check the URL and " <>
                 "that a grant covers the target" <>
                 @suffix
    end

    test "server_error" do
      assert TokenUnavailableError.message(@url, {:server_error, 503}) ==
               @prefix <>
                 "intake failed to issue a token (HTTP 503); this may be transient" <>
                 @suffix
    end

    test "transport_error" do
      for reason <- [
            {:transport_error, %Req.TransportError{reason: :econnrefused}},
            {:transport_error, :timeout}
          ] do
        assert TokenUnavailableError.message(@url, reason) == @prefix <> @transport <> @suffix
      end
    end

    test "the mint threw" do
      for reason <- [
            {:transport_error, %RuntimeError{message: "exploded with s3cret"}},
            {:transport_error, {:throw, "s3cret"}},
            {:transport_error, {:exit, "s3cret"}}
          ] do
        assert TokenUnavailableError.message(@url, reason) ==
                 @prefix <> "the token request failed unexpectedly" <> @suffix
      end
    end

    test "no result recorded" do
      assert TokenUnavailableError.message(@url, nil) ==
               @prefix <> "the token request failed for an unknown reason" <> @suffix
    end
  end
end
