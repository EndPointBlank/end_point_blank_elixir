defmodule EndPointBlank.TokenUnavailableErrorMessageTest do
  # The message is what reaches logs and error reporting, and the caller
  # controls the URL in it, so it must never repeat the URL's userinfo, query
  # or fragment (sc-1469 review on js#54).
  use ExUnit.Case, async: true

  alias EndPointBlank.TokenUnavailableError

  @raw "https://user:hunter2@api.provider.test:8443/v1/things?api_key=s3cret#frag"

  test "the message names only scheme, host and path" do
    message = Exception.message(TokenUnavailableError.exception(base_url: @raw))

    assert message =~ "for https://api.provider.test:8443/v1/things: "

    for secret <- ~w(user hunter2 api_key s3cret frag) do
      refute message =~ secret
    end
  end

  test "the raw URL stays on the exception" do
    assert TokenUnavailableError.exception(base_url: @raw).base_url == @raw
  end

  test "an unparseable URL is left out of the message" do
    message = TokenUnavailableError.message("not a url ?token=s3cret", nil)

    refute message =~ "s3cret"
    assert message =~ "could not be parsed"
  end
end
