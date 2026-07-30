defmodule EndPointBlank.Phoenix.VersionedTest do
  @moduledoc """
  `version_of/2` had no test coverage before this — the suite passed the flat-array
  change without exercising it once. These pin the merge semantics the manifest
  depends on.
  """
  use ExUnit.Case, async: true

  defmodule SingleController do
    use EndPointBlank.Phoenix.Versioned

    version_of(:index, ["v1", "v2"])
  end

  defmodule MergingController do
    use EndPointBlank.Phoenix.Versioned

    version_of(:index, ["v1", "v2"])
    version_of(:index, ["v2", "v3"])
    version_of(:show, ["v1"])
  end

  defmodule EmptyController do
    use EndPointBlank.Phoenix.Versioned

    version_of(:index, [])
  end

  defmodule UndeclaredController do
    use EndPointBlank.Phoenix.Versioned
  end

  test "records versions as a flat list" do
    assert SingleController.__epb_versions__() == %{index: ["v1", "v2"]}
  end

  test "repeated declarations merge, deduplicated, in declaration order" do
    # Order matters: a manifest that reorders between deploys churns the payload
    # and makes every deploy look like a change.
    assert MergingController.__epb_versions__() == %{
             index: ["v1", "v2", "v3"],
             show: ["v1"]
           }
  end

  test "an action declared with no versions records an empty list" do
    assert EmptyController.__epb_versions__() == %{index: []}
  end

  test "a controller with no declarations records nothing" do
    assert UndeclaredController.__epb_versions__() == %{}
  end

  test "version_of/3 no longer exists" do
    # The `state:` option is removed rather than accepted and ignored: a
    # silently discarded option is worse than a compile error.
    refute function_exported?(EndPointBlank.Phoenix.Versioned, :version_of, 3)
  end
end
