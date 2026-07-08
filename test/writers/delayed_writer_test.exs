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
    assert length(state[:errors]) == 10
    assert state[:errors] == payloads(10)
  end

  test "enqueuing more than the cap drops the oldest and retains only the newest max", %{
    pid: pid
  } do
    over = 1_500

    capture_log(fn ->
      GenServer.cast(pid, {:enqueue, :errors, payloads(over)})
      queue = :sys.get_state(pid)[:errors]
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

    queue = :sys.get_state(pid)[:errors]
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
end
