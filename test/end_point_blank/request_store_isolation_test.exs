defmodule EndPointBlank.RequestStoreIsolationTest do
  @moduledoc """
  Request-to-request isolation.

  Elixir gets this differently from the other SDKs. Ruby, Python and Java hold
  the request in a thread-local and threads are reused, so per-request data had
  to move onto the request object itself. Here the store is the process
  dictionary, and Phoenix allocates a process per request that it does not
  reuse — so the isolation is structural.

  Two things are therefore worth pinning:

    * across processes, nothing is shared — the property Phoenix relies on;
    * within one process the values persist until cleared, which is why
      `EndPointBlank.Plug.ReportInteraction` clears in `register_before_send`.

  The second is a real constraint, not an implementation detail: anything using
  this store in a long-lived process (a GenServer, a pooled worker) must clear
  between units of work or it will read the previous one's data.
  """
  use ExUnit.Case, async: true

  alias EndPointBlank.RequestStore

  setup do
    on_exit(&RequestStore.clear/0)
    RequestStore.clear()
    :ok
  end

  describe "across processes" do
    test "one process cannot see another's values" do
      parent = self()

      spawn(fn ->
        RequestStore.put_source_env_id("app-env-other")
        RequestStore.put_uuid("uuid-other")
        send(parent, :written)
        # Stay alive so the values are not merely gone with the process.
        receive do: (:stop -> :ok)
      end)

      assert_receive :written, 1_000

      assert RequestStore.get_source_env_id() == nil
      assert RequestStore.get_uuid() == nil
    end

    test "concurrent processes each keep their own" do
      parent = self()

      for id <- ["one", "two", "three"] do
        spawn(fn ->
          RequestStore.put_source_env_id(id)
          # Give the others time to write before reading, so a shared slot
          # would be visibly wrong rather than accidentally right.
          Process.sleep(20)
          send(parent, {id, RequestStore.get_source_env_id()})
        end)
      end

      for id <- ["one", "two", "three"] do
        assert_receive {^id, ^id}, 2_000
      end
    end

    test "a Phoenix-style fresh process starts empty even after a busy predecessor" do
      parent = self()

      first = spawn(fn -> RequestStore.put_source_env_id("app-env-first") end)
      ref = Process.monitor(first)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      spawn(fn -> send(parent, {:second, RequestStore.get_source_env_id()}) end)

      assert_receive {:second, nil}, 1_000
    end
  end

  describe "within one process" do
    test "clear/0 removes every value, which is what the plug relies on" do
      RequestStore.put_source_env_id("app-env-123")
      RequestStore.put_uuid("uuid-123")
      RequestStore.put_conn(%{stub: true})

      RequestStore.clear()

      assert RequestStore.get_source_env_id() == nil
      assert RequestStore.get_uuid() == nil
      assert RequestStore.get_conn() == nil
    end

    test "values persist until cleared — the constraint the plug exists to satisfy" do
      # Asserted deliberately rather than left implicit. Unlike the other SDKs,
      # isolation here depends on either a fresh process or an explicit clear;
      # anything reusing a process for two units of work must call clear/0.
      RequestStore.put_source_env_id("app-env-123")

      assert RequestStore.get_source_env_id() == "app-env-123"
    end

    test "a second unit of work sees nothing once cleared" do
      RequestStore.put_source_env_id("app-env-first")
      RequestStore.clear()

      # Models what ReportInteraction does at the end of every request.
      assert RequestStore.get_source_env_id() == nil
    end
  end
end
