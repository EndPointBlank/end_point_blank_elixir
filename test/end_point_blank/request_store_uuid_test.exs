defmodule EndPointBlank.RequestStoreUuidTest do
  @moduledoc """
  The per-request uuid is the join key between a request row, its response row,
  and every log line and error written during it. A collision merges two
  unrelated requests in the portal, so uniqueness is the property under test.
  """
  use ExUnit.Case, async: true

  alias EndPointBlank.RequestStore

  @uuid_v4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "generates a syntactically valid version 4 UUID" do
    assert RequestStore.generate_uuid() =~ @uuid_v4
  end

  test "generates a different value every time" do
    generated = for _ <- 1..1_000, do: RequestStore.generate_uuid()

    assert length(Enum.uniq(generated)) == 1_000
  end

  test "zero-pads every field to full width" do
    # Small random values must not shorten a field; a 35-character uuid is
    # rejected by anything parsing the canonical form.
    assert Enum.all?(for(_ <- 1..500, do: RequestStore.generate_uuid()), &(byte_size(&1) == 36))
  end

  test "uses lowercase hex throughout" do
    uuid = RequestStore.generate_uuid()

    assert uuid == String.downcase(uuid)
  end
end
