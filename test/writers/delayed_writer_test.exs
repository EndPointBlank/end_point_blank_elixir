defmodule EndPointBlank.Writers.DelayedWriterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
end
