defmodule EndPointBlank.HttpTest do
  use ExUnit.Case, async: false

  alias EndPointBlank.Http

  setup do
    on_exit(fn -> Application.delete_env(:end_point_blank_elixir, :req_test_plug) end)
  end

  describe "req_options/0" do
    test "sets a bounded receive_timeout so a hung intake cannot block forever" do
      opts = Http.req_options()
      assert opts[:receive_timeout] == 5_000
    end

    test "sets a bounded connect timeout" do
      opts = Http.req_options()
      assert opts[:connect_options] == [timeout: 3_000]
    end
  end

  describe "post/3 end-to-end via Req.Test stub" do
    test "returns {:ok, resp} on success and the stub observes the bounded options" do
      Application.put_env(
        :end_point_blank_elixir,
        :req_test_plug,
        {Req.Test, __MODULE__.SuccessStub}
      )

      Req.Test.stub(__MODULE__.SuccessStub, fn conn ->
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %Req.Response{status: 200}} =
               Http.post("https://example.test/x", %{a: 1}, "Bearer token")
    end

    test "retries up to 3 attempts and returns {:error, reason} when the stub always errors" do
      Application.put_env(
        :end_point_blank_elixir,
        :req_test_plug,
        {Req.Test, __MODULE__.FailStub}
      )

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__.FailStub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Http.post("https://example.test/x", %{a: 1}, "Bearer token")

      assert Agent.get(counter, & &1) == 3
    end
  end
end
