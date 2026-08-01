defmodule EndPointBlank.UnauthorizedErrorTest do
  use ExUnit.Case, async: true

  alias EndPointBlank.UnauthorizedError

  test "carries a message given as a keyword option" do
    assert_raise UnauthorizedError, "no grant for this endpoint", fn ->
      raise UnauthorizedError, message: "no grant for this endpoint"
    end
  end

  test "carries a message given as a bare string" do
    # `raise Mod, "text"` is the idiomatic form and must not produce an
    # exception whose message is the string "Unauthorized".
    assert_raise UnauthorizedError, "no grant for this endpoint", fn ->
      raise UnauthorizedError, "no grant for this endpoint"
    end
  end

  test "falls back to a usable default message" do
    assert_raise UnauthorizedError, "Unauthorized", fn -> raise UnauthorizedError end
  end

  test "is rescuable by its own module name" do
    # ReportInteraction distinguishes this from an application defect by
    # matching on the struct, so it must be an ordinary named exception.
    result =
      try do
        raise UnauthorizedError
      rescue
        e in UnauthorizedError -> {:rescued, Exception.message(e)}
      end

    assert result == {:rescued, "Unauthorized"}
  end
end
