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

    # Applications set this seam in their own tests, and not always to a
    # {Req.Test, name} tuple: epb_test_ex installs a bare function. Req 0.7
    # moved `:plug` from the run_plug step to the Req.Plug adapter, and
    # `{:req, "~> 0.5"}` admits every 0.x from 0.5 on, so the shape an
    # application uses is pinned here rather than assumed.
    test "accepts a bare function plug, which receives the JSON body" do
      Application.put_env(:end_point_blank_elixir, :req_test_plug, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, raw)
      end)

      assert {:ok, %Req.Response{status: 201, body: %{"a" => 1}}} =
               Http.post("https://example.test/x", %{a: 1}, "Basic abc")
    end
  end
end
