defmodule EndPointBlank.Writers.DelayedWriterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EndPointBlank.Config
  alias EndPointBlank.Writers.DelayedWriter

  # Each test starts its own uniquely-named instance so it doesn't race with
  # the globally-supervised DelayedWriter's own 100 ms flush/reset cycle.
  setup do
    name = :"delayed_writer_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = DelayedWriter.start_link(name: name)
    %{pid: pid}
  end

  defp payloads(n), do: for(i <- 1..n, do: %{n: i})

  test "an under-cap enqueue keeps everything", %{pid: pid} do
    GenServer.cast(pid, {:enqueue, :errors, payloads(10)})

    state = :sys.get_state(pid)
    assert length(state.queues[:errors]) == 10
    assert state.queues[:errors] == payloads(10)
  end

  test "enqueuing more than the cap drops the oldest and retains only the newest max", %{
    pid: pid
  } do
    over = 1_500

    capture_log(fn ->
      GenServer.cast(pid, {:enqueue, :errors, payloads(over)})
      queue = :sys.get_state(pid).queues[:errors]
      assert length(queue) == 1_000
      # newest payloads are retained (oldest dropped), so the tail matches
      assert queue == payloads(over) |> Enum.take(-1_000)
    end)
  end

  test "crossing the cap logs a throttled warning noting how many were dropped", %{pid: pid} do
    log =
      capture_log(fn ->
        GenServer.cast(pid, {:enqueue, :errors, payloads(1_200)})
        :sys.get_state(pid)
      end)

    assert log =~ "dropping"
    assert log =~ "200"
  end

  test "does not re-log on every subsequent cast once already saturated", %{pid: pid} do
    log =
      capture_log(fn ->
        GenServer.cast(pid, {:enqueue, :errors, payloads(1_200)})
        :sys.get_state(pid)
        GenServer.cast(pid, {:enqueue, :errors, payloads(5)})
        :sys.get_state(pid)
        GenServer.cast(pid, {:enqueue, :errors, payloads(5)})
        :sys.get_state(pid)
      end)

    occurrences =
      log
      |> String.split("\n")
      |> Enum.count(&(&1 =~ "dropping"))

    assert occurrences == 1

    queue = :sys.get_state(pid).queues[:errors]
    assert length(queue) == 1_000
  end

  describe "flush concurrency honors Config.worker_count/0" do
    setup do
      # DirectWriter.write runs inside Task.async_stream tasks spawned from
      # the DelayedWriter process (not the test process), so the stub must
      # be visible process-wide.
      Req.Test.set_req_test_to_shared()

      Application.put_env(
        :end_point_blank_elixir,
        :req_test_plug,
        {Req.Test, __MODULE__.ConcurrencyStub}
      )

      on_exit(fn ->
        Config.reset()
        Application.delete_env(:end_point_blank_elixir, :req_test_plug)
        Req.Test.set_req_test_to_private()
      end)

      :ok
    end

    defp start_concurrency_tracker do
      {:ok, tracker} = Agent.start_link(fn -> %{current: 0, max: 0} end)
      tracker
    end

    defp stub_tracking_concurrency(tracker, sleep_ms) do
      Req.Test.stub(__MODULE__.ConcurrencyStub, fn conn ->
        Agent.update(tracker, fn %{current: current, max: max} ->
          %{current: current + 1, max: max(max, current + 1)}
        end)

        Process.sleep(sleep_ms)

        Agent.update(tracker, fn state -> %{state | current: state.current - 1} end)

        Req.Test.json(conn, %{"ok" => true})
      end)
    end

    # Enqueues one full batch (@batch_size payloads, i.e. exactly one chunk)
    # per given url_key, then triggers and synchronously waits for a flush.
    defp enqueue_one_batch_per_key(pid, url_keys) do
      Enum.each(url_keys, &GenServer.cast(pid, {:enqueue, &1, payloads(4)}))
      :sys.get_state(pid)

      send(pid, :flush)
      # handle_info(:flush, ...) doesn't reply until every spawned write task
      # completes, so this synchronizes with the end of the flush.
      :sys.get_state(pid)
    end

    test "serializes writes when worker_count is 1", %{pid: pid} do
      Config.update(worker_count: 1)
      tracker = start_concurrency_tracker()
      stub_tracking_concurrency(tracker, 50)

      enqueue_one_batch_per_key(pid, [:requests, :responses, :logs])

      assert Agent.get(tracker, & &1.max) == 1
    end

    test "parallelizes writes up to the configured worker_count", %{pid: pid} do
      Config.update(worker_count: 3)
      tracker = start_concurrency_tracker()
      stub_tracking_concurrency(tracker, 100)

      enqueue_one_batch_per_key(pid, [:requests, :responses, :logs])

      assert Agent.get(tracker, & &1.max) == 3
    end

    test "does not exceed worker_count even with more batches in flight", %{pid: pid} do
      Config.update(worker_count: 2)
      tracker = start_concurrency_tracker()
      stub_tracking_concurrency(tracker, 100)

      enqueue_one_batch_per_key(pid, [:requests, :responses, :logs, :errors])

      assert Agent.get(tracker, & &1.max) == 2
    end
  end

  # A failing batch used to be a failing process. `Task.async_stream/3` links
  # its tasks to the caller — this GenServer — so a raise or exit in any batch
  # sent an exit signal here, at a 100 ms cadence, against a supervisor whose
  # default intensity is three restarts in five seconds. Under
  # `start_permanent` (mix.exs:11) that terminates the application and halts
  # the node. These tests induce the real failures rather than asserting on a
  # stubbed writer: the stub below is the transport, and it fails for real
  # inside the real `DirectWriter.write/2` call path.
  describe "a batch that fails cannot take the writer down" do
    setup do
      # DirectWriter.write runs inside Task.async_stream tasks spawned from
      # the DelayedWriter process (not the test process), so the stub must
      # be visible process-wide.
      Req.Test.set_req_test_to_shared()

      Application.put_env(
        :end_point_blank_elixir,
        :req_test_plug,
        {Req.Test, __MODULE__.FailureStub}
      )

      on_exit(fn ->
        Config.reset()
        Application.delete_env(:end_point_blank_elixir, :req_test_plug)
        Req.Test.set_req_test_to_private()
      end)

      :ok
    end

    # A real supervisor with the real default restart intensity, so "the
    # writer survived" means the supervisor never had to act at all, and the
    # node-level claim is not a figure of speech: exceeding that intensity
    # terminates this supervisor, which is what terminates the application in
    # a permanent release.
    defp start_supervised_writer do
      name = :"delayed_writer_supervised_#{System.unique_integer([:positive])}"

      {:ok, sup} =
        Supervisor.start_link(
          [%{id: name, start: {DelayedWriter, :start_link, [[name: name]]}}],
          strategy: :one_for_one
        )

      {sup, name, Process.whereis(name)}
    end

    defp enqueue(name, url_key, count) do
      case Process.whereis(name) do
        nil -> :writer_is_dead
        pid -> GenServer.cast(pid, {:enqueue, url_key, payloads(count)})
      end
    end

    # Triggers one flush and blocks until it has finished — handle_info(:flush,
    # ...) drains synchronously, so a completed :sys.get_state means a
    # completed flush. Tolerating a dead writer is what makes the pre-change
    # failure read as a clear assertion rather than an exit cascade that takes
    # the test process with it.
    defp flush_and_wait(name) do
      case Process.whereis(name) do
        nil ->
          :writer_is_dead

        pid ->
          send(pid, :flush)

          try do
            :sys.get_state(pid)
            :ok
          catch
            :exit, _ -> :writer_is_dead
          end
      end
    end

    defp stub_raising(message) do
      Req.Test.stub(__MODULE__.FailureStub, fn _conn -> raise message end)
    end

    defp stub_reporting_delivery(test_pid) do
      Req.Test.stub(__MODULE__.FailureStub, fn conn ->
        send(test_pid, :delivered)
        Req.Test.json(conn, %{"ok" => true})
      end)
    end

    # Takes the config store down for real, through the library's own
    # supervisor: terminating that child destroys the ETS table it owns, which
    # is what a reader sees while the config process is down or between
    # restarts. `terminate_child/2` returns only once the child is dead, so the
    # window is deterministic rather than raced.
    #
    # This used to unregister the Agent's *name* instead, because the read was
    # an `Agent.get/2` and a missing name was enough to make it exit. Since
    # sc-350 the read goes to a named table rather than to the process, so
    # unregistering the name breaks nothing at all — a test written that way
    # would now pass while proving nothing.
    defp with_config_store_down(fun) do
      :ok = Supervisor.terminate_child(EndPointBlank.Supervisor, Config)

      try do
        fun.()
      after
        {:ok, _pid} = Supervisor.restart_child(EndPointBlank.Supervisor, Config)
      end
    end

    test "a raise inside a batch leaves the writer, its supervisor and the node standing" do
      Process.flag(:trap_exit, true)
      stub_raising("intake blew up mid-batch")

      {sup, name, writer} = start_supervised_writer()

      # Six failing flushes in far less than five seconds. Before this change
      # the first killed the writer and the fourth exhausted the supervisor.
      capture_log(fn ->
        for _ <- 1..6 do
          enqueue(name, :errors, 4)
          assert flush_and_wait(name) == :ok
        end
      end)

      assert Process.alive?(writer), "the writer process died"
      assert Process.whereis(name) == writer, "the writer was restarted"
      assert Process.alive?(sup), "the supervisor gave up"
      refute_received {:EXIT, ^sup, _}

      # The node is still up: the library's own supervision tree is intact and
      # its application is still running.
      assert is_pid(Process.whereis(DelayedWriter))
      assert List.keymember?(Application.started_applications(), :end_point_blank_elixir, 0)

      # And it is not merely alive but still working — the next batch lands.
      stub_reporting_delivery(self())
      enqueue(name, :errors, 4)
      assert flush_and_wait(name) == :ok
      assert_received :delivered
    end

    test "an Agent.get timeout inside a batch costs the batch, not the writer" do
      # The story's own path, induced for real: a genuinely blocked Agent and a
      # genuinely expiring Agent.get/3, which exits its caller rather than
      # raising. That caller is the write task, and an exiting task signals the
      # GenServer over its link exactly as a raising one does.
      {:ok, blocked} = Agent.start(fn -> :state end)
      Agent.cast(blocked, fn state -> Process.sleep(5_000) && state end)
      on_exit(fn -> Process.exit(blocked, :kill) end)

      Req.Test.stub(__MODULE__.FailureStub, fn _conn -> Agent.get(blocked, & &1, 10) end)

      Process.flag(:trap_exit, true)
      {sup, name, writer} = start_supervised_writer()

      log =
        capture_log(fn ->
          enqueue(name, :errors, 4)
          assert flush_and_wait(name) == :ok
        end)

      assert Process.alive?(writer), "an exiting task took the writer down"
      assert Process.whereis(name) == writer
      assert Process.alive?(sup)
      assert log =~ "recovered from (exit)"
      assert log =~ "timeout"
    end

    test "a config store that is down costs the flush, not the writer" do
      # `Config.worker_count/0` is an argument to Task.async_stream/3, so it is
      # evaluated in the writer process before a single task exists. Nothing
      # inside a task can guard it, and before sc-331 it killed the writer with
      # no batch having failed at all.
      #
      # sc-350 changed what that failure is, not who dies for it. The read was
      # an `Agent.get/2` that exited its caller after five seconds; it is now an
      # ETS lookup that raises at once when the store is gone. The flush guard
      # catches all three kinds, so it still covers this — and this test still
      # fails without it.
      Process.flag(:trap_exit, true)
      {sup, name, writer} = start_supervised_writer()
      enqueue(name, :errors, 4)

      {result, log} =
        with_log(fn ->
          with_config_store_down(fn -> flush_and_wait(name) end)
        end)

      assert result == :ok, "the writer died evaluating Config.worker_count/0"
      assert Process.alive?(writer)
      assert Process.whereis(name) == writer
      assert Process.alive?(sup)

      # The failure is the loud one, named in full: a raise about the config
      # store, not a five-second exit and not a silently defaulted worker count.
      assert log =~ "recovered from (RuntimeError)"
      assert log =~ "EndPointBlank.Config is unavailable"
      assert log =~ "the tick was lost before any batch was sent"
    end

    test "an idle flush does not reach for Config at all" do
      # With nothing queued there is nothing to send, so the writer must not
      # read config at all. A downed store proves it: were the read still made,
      # the guard would catch the raise and say so.
      Process.flag(:trap_exit, true)
      {_sup, name, writer} = start_supervised_writer()

      {result, log} =
        with_log(fn ->
          with_config_store_down(fn -> flush_and_wait(name) end)
        end)

      assert result == :ok
      assert Process.whereis(name) == writer
      refute log =~ "recovered from"
    end

    test "a failing flush is one log line, naming the failure and what it cost" do
      Process.flag(:trap_exit, true)
      stub_raising("intake blew up mid-batch")
      {_sup, name, _writer} = start_supervised_writer()

      # 12 payloads is three batches of @batch_size, all of which fail.
      log =
        capture_log(fn ->
          enqueue(name, :errors, 12)
          assert flush_and_wait(name) == :ok
        end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "DelayedWriter recovered from"))

      assert length(lines) == 1, "expected one line for one fault, got #{length(lines)}"
      [line] = lines
      assert line =~ "(RuntimeError) intake blew up mid-batch"
      assert line =~ "consecutive failure 1"
      assert line =~ "3 batch(es) and 12 payload(s) lost"
      assert line =~ "retrying in 1.0s"
      # The frame names where the failure actually happened, not where it was
      # caught — here, the transport stub that raised.
      assert line =~ "delayed_writer_test.exs"
    end

    test "consecutive failures escalate the retry interval, and a clean flush resets it" do
      Process.flag(:trap_exit, true)
      stub_raising("intake blew up mid-batch")
      {_sup, name, writer} = start_supervised_writer()

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            enqueue(name, :errors, 4)
            assert flush_and_wait(name) == :ok
          end
        end)

      assert log =~ "consecutive failure 1"
      assert log =~ "retrying in 1.0s"
      assert log =~ "consecutive failure 2"
      assert log =~ "retrying in 2.0s"
      assert log =~ "consecutive failure 3"
      assert log =~ "retrying in 4.0s"
      assert :sys.get_state(writer).consecutive_failures == 3

      # One clean flush puts the counter back to zero...
      stub_reporting_delivery(self())
      enqueue(name, :errors, 4)
      assert flush_and_wait(name) == :ok
      assert_received :delivered
      assert :sys.get_state(writer).consecutive_failures == 0

      # ...so the next fault starts its story over rather than resuming at 4.
      stub_raising("intake blew up mid-batch")

      restarted_log =
        capture_log(fn ->
          enqueue(name, :errors, 4)
          assert flush_and_wait(name) == :ok
        end)

      assert restarted_log =~ "consecutive failure 1"
      assert restarted_log =~ "retrying in 1.0s"
    end

    test "a backed-off writer really does stop flushing at the base cadence" do
      Process.flag(:trap_exit, true)
      stub_raising("intake blew up mid-batch")
      {_sup, name, writer} = start_supervised_writer()

      # Four consecutive failures arm the next tick 8s out, not 1s.
      capture_log(fn ->
        for _ <- 1..4 do
          enqueue(name, :errors, 4)
          assert flush_and_wait(name) == :ok
        end
      end)

      # The armed timer is the backoff, not the base cadence — read from the
      # live timer rather than inferred.
      armed_ms = Process.read_timer(:sys.get_state(writer).flush_timer)
      assert armed_ms > 4_000, "next tick was armed only #{armed_ms}ms out"

      stub_reporting_delivery(self())
      enqueue(name, :errors, 4)

      # An un-backed-off writer would have flushed this within one second.
      refute_receive :delivered, 1_500

      # And the silence is the backoff rather than a dead writer or an empty
      # queue: the same payloads go out the moment a flush actually runs.
      assert Process.whereis(name) == writer
      assert flush_and_wait(name) == :ok
      assert_received :delivered
    end

    test "an exit signal from outside a task is still fatal, by design" do
      # The deliberate boundary, pinned so that widening write_batch/1's catch
      # to chase it fails the suite. An asynchronous kill is untrappable: the
      # task cannot catch it and the link delivers it here. It means something
      # outside this library is tearing processes down on purpose, and
      # fire-and-forget telemetry has no business outliving that.
      Process.flag(:trap_exit, true)
      test_pid = self()

      Req.Test.stub(__MODULE__.FailureStub, fn conn ->
        send(test_pid, {:task_running, self()})
        Process.sleep(2_000)
        Req.Test.json(conn, %{"ok" => true})
      end)

      name = :"delayed_writer_boundary_#{System.unique_integer([:positive])}"
      {:ok, writer} = DelayedWriter.start_link(name: name)
      ref = Process.monitor(writer)

      GenServer.cast(writer, {:enqueue, :errors, payloads(4)})
      send(writer, :flush)

      assert_receive {:task_running, task}, 2_000
      Process.exit(task, :kill)

      assert_receive {:DOWN, ^ref, :process, ^writer, :killed}, 2_000
    end
  end
end
