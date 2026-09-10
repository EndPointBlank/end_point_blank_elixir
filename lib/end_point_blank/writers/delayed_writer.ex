defmodule EndPointBlank.Writers.DelayedWriter do
  @moduledoc """
  Background queue that batches payloads and flushes them on a timer.

  Payloads for each URL key are accumulated in the GenServer state and sent
  in batches of up to #{4} via `DirectWriter` on each flush tick. Batches
  (across all URL keys) are flushed concurrently, bounded by
  `EndPointBlank.Config.worker_count/0` (default 4), so a flush tick never
  fires more than that many writes in flight at once.

  Each URL key's queue is capped at #{1_000} payloads. If an intake outage
  (or any slow/hung downstream) causes payloads to accumulate faster than
  they can be flushed, the oldest payloads for that key are dropped to keep
  memory usage bounded in the host app.

  ## A failing batch costs that batch, never this process

  This is fire-and-forget telemetry embedded in someone else's application.
  Nothing it does may be able to stop that application, so every way a flush
  can fail is contained and reported rather than allowed to propagate:

    * `write_batch/1` catches inside the task, which is the only place a
      batch's failure can be stopped — see the note there for why a `try`
      around `Task.async_stream/3` cannot do it;
    * the flush callback guards what it evaluates itself, which includes
      `EndPointBlank.Config.worker_count/0` — a config read that fails in
      *this* process, not in a task, when the config store is unavailable;
    * a recovered failure is logged loudly, once per failing tick, and the
      tick interval backs off exponentially while failures continue, so a
      persistent fault reads as one escalating line rather than a hot loop.

  The one thing deliberately left to propagate is an exit signal delivered to
  a task from outside it; `write_batch/1` documents that boundary.
  """

  use GenServer
  require Logger

  @batch_size 4
  @max_queue_per_key 1_000

  # The base tick, and the retry interval a failing tick backs off from.
  #
  # This was 100 ms, which bought very little batching (at any realistic rate
  # a 100 ms window holds a handful of payloads, so the @batch_size chunking
  # barely engages) and cost a great deal: ten wakeups per second forever in
  # every host app, ten `Agent.get/2` round trips per second to the Config
  # agent (until sc-350 made that read a lock-free ETS lookup), and — before
  # this module guarded anything — up to ten crash-and-restart cycles per
  # second against a supervisor whose default intensity is three restarts in
  # five seconds. A second is still well inside "delayed" for telemetry nobody
  # is waiting on, and it makes a batch a batch.
  @flush_ms 1_000
  @max_flush_backoff_ms 30_000

  # Bounds the exponent in next_flush_ms/1. The delay itself is capped anyway,
  # but a fault that persists overnight reaches a five-figure failure count,
  # and `2 ** 30_000` is a bignum this process would otherwise compute on
  # every tick to no purpose — the cap has applied since the sixth failure.
  @max_backoff_doublings 8

  # `queues` is the per-URL-key backlog; `consecutive_failures` counts flush
  # ticks that failed in a row (not failed batches, and not failed writes —
  # see handle_info/2) and drives both the log line and the backoff;
  # `flush_timer` is the one outstanding tick (see schedule_flush/2).
  defstruct queues: %{}, consecutive_failures: 0, flush_timer: nil

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @doc "Enqueues `payloads` to be sent to `url_key` on the next flush."
  def write(url_key, payloads) when is_list(payloads) do
    GenServer.cast(__MODULE__, {:enqueue, url_key, payloads})
  end

  # Callbacks

  @impl true
  def init(_) do
    {:ok, schedule_flush(%__MODULE__{})}
  end

  @impl true
  def handle_cast({:enqueue, url_key, payloads}, %__MODULE__{queues: queues} = state) do
    existing = Map.get(queues, url_key, [])
    combined = existing ++ payloads
    total = length(combined)

    retained =
      if total > @max_queue_per_key do
        maybe_log_drop(url_key, existing, total)
        Enum.take(combined, -@max_queue_per_key)
      else
        combined
      end

    {:noreply, %{state | queues: Map.put(queues, url_key, retained)}}
  end

  @impl true
  def handle_info(:flush, %__MODULE__{} = state) do
    # A tick counts as one failure however many of its batches failed: four
    # batches lost to one unreachable dependency is one fault, not four. Note
    # that a write which merely *fails* — a non-2xx, or a transport error that
    # outlasts `Http`'s retries — is not counted here at all. DirectWriter
    # already logs those, they are an expected outcome of talking to a network,
    # and escalating the tick interval for them would change delivery
    # behaviour for a case that already works as designed. Only a flush that
    # raised, exited or threw is a defect, and only defects back off.
    consecutive_failures =
      case flush(state.queues) do
        :ok ->
          0

        {:recovered, failures} ->
          consecutive_failures = state.consecutive_failures + 1
          log_recovered(failures, consecutive_failures)
          consecutive_failures
      end

    # The queue is released whether or not the tick succeeded. A batch that
    # failed is lost, exactly as it was before: re-queueing it would fight the
    # per-key cap during precisely the outage the cap exists for.
    state = %{state | queues: %{}, consecutive_failures: consecutive_failures}

    {:noreply, schedule_flush(state, next_flush_ms(consecutive_failures))}
  end

  # Nothing queued. Returning here is not only an optimisation: it keeps an
  # idle host app from touching the config store once a tick, forever — the
  # store whose unavailability is still the likeliest way for this callback to
  # fail at all, even now that reaching it costs an ETS lookup rather than a
  # message round trip.
  defp flush(queues) when map_size(queues) == 0, do: :ok

  defp flush(queues) do
    case collect_failures(queues) do
      [] -> :ok
      failures -> {:recovered, Enum.reverse(failures)}
    end
  end

  defp collect_failures(queues) do
    queues
    |> batches()
    |> Task.async_stream(
      &write_batch/1,
      max_concurrency: EndPointBlank.Config.worker_count(),
      # Http already bounds each attempt (and its retries); let it own the
      # timeout instead of racing it here.
      timeout: :infinity
    )
    # write_batch/1 cannot fail, so every element is `{:ok, _}`. The only way
    # an `{:exit, _}` could appear is the asynchronous kill described there,
    # and that reaches this process as a signal before the stream ever yields
    # it. Matching only `{:ok, _}` therefore states an invariant rather than
    # ignoring a case — and if it were ever wrong, the FunctionClauseError is
    # raised in this process, where the catch below reports it loudly.
    |> Enum.reduce([], fn
      {:ok, :ok}, failures -> failures
      {:ok, {:failed, failure}}, failures -> [failure | failures]
    end)
  catch
    # This is NOT what protects the writer from a failing batch. A task's death
    # arrives as an asynchronous exit signal over its link, and a signal is not
    # an exception: a `try` wrapped around `Task.async_stream/3` does not stop a
    # raising task from taking its caller down. That is write_batch/1's job.
    #
    # What this covers is everything the flush evaluates in *this* process:
    # batches/1, the reduce above, and `EndPointBlank.Config.worker_count/0`.
    # That last call is an argument to `Task.async_stream/3`, so it runs here,
    # before a single task is spawned — nothing inside a task can guard it, and
    # an unguarded failure there kills this process without any batch having
    # failed at all.
    #
    # sc-350 changed what that failure *is* and not who dies for it. The config
    # read used to be an `Agent.get/2` carrying a 5000 ms default timeout that
    # exited its caller; it is now a lock-free ETS lookup that raises when the
    # config store is down. A raise ends this process exactly as thoroughly as
    # an exit did, so this guard is still load-bearing — `kind, reason` catches
    # all three kinds and needed no change to keep covering it.
    kind, reason ->
      [%{scope: :flush, payloads: 0, kind: kind, reason: reason, stack: __STACKTRACE__}]
  end

  defp batches(queues) do
    Enum.flat_map(queues, fn {url_key, payloads} ->
      payloads
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(&{url_key, &1})
    end)
  end

  # Runs inside the task, which is the only place this guard can go.
  #
  # `Task.async_stream/3` links its tasks to the caller — here, the GenServer
  # itself. A task that raises, exits or throws dies, and its link then
  # delivers an exit signal to this process, which is not trapping exits and
  # so dies with it. Nothing at the call site can intercept that signal, which
  # is why the containment has to happen before the failure ever becomes one:
  # a batch that cannot die cannot signal anything.
  #
  # `:error`, `:exit` and `:throw` together are everything a batch can do to
  # itself. `:exit` matters as much as `:error` here — the `GenServer.call/3`
  # timeouts reachable from `DirectWriter.write/2` exit their caller rather
  # than raising, and a test pins that with a real one.
  #
  # Deliberately NOT covered: an exit signal delivered to the task from
  # *outside* it — `Process.exit(task_pid, :kill)`, a `max_heap_size` breach,
  # a `:brutal_kill` shutdown. Those are untrappable by design and still reach
  # this GenServer over the link, ending it. That boundary is the analogue of
  # sc-318's `rescue StandardError`: it means something outside this library is
  # deliberately tearing processes down, and fire-and-forget telemetry has no
  # business arguing with that. A test pins it, so widening this catch to try
  # to cover it fails the suite.
  #
  # An unlinked stream (`Task.Supervisor.async_stream_nolink/4`) would survive
  # that last case too, and it was rejected for three reasons. It lets the
  # crash actually happen, so Elixir's own task-crash report is logged in full
  # for every failed batch, ahead of — and immune to — the throttled line this
  # module emits, which is the log storm this change exists to prevent. It
  # decouples task lifetime from the writer's, so an in-flight POST can outlive
  # the writer and the shutting-down application it belongs to. And it reports
  # a failure as an opaque `{:exit, reason}` rather than as a value carrying
  # the URL key and payload count that make the log line worth reading.
  defp write_batch({url_key, batch}) do
    EndPointBlank.Writers.DirectWriter.write(url_key, batch)
    :ok
  catch
    kind, reason ->
      {:failed,
       %{
         scope: {:batch, url_key},
         payloads: length(batch),
         kind: kind,
         reason: reason,
         stack: __STACKTRACE__
       }}
  end

  # One line per failing tick — not one per failing batch, and emphatically not
  # the ten supervisor crash reports a second this used to produce. The line
  # names the first failure in full, counts what went with it, and says when
  # the next attempt is, so a persistent fault reads as a single escalating
  # story: "consecutive failure 12 ... retrying in 30.0s".
  defp log_recovered([first | _] = failures, consecutive_failures) do
    retry_in_s = Float.round(next_flush_ms(consecutive_failures) / 1_000, 1)

    Logger.error(
      "[EndPointBlank] DelayedWriter recovered from #{format_failure(first)} " <>
        "(consecutive failure #{consecutive_failures}); #{cost(failures)}, " <>
        "retrying in #{retry_in_s}s at #{top_frame(first.stack)}"
    )
  end

  # A failure in the callback itself lost the tick before any batch existed;
  # saying "1 batch(es) and 0 payload(s)" would misdescribe it.
  defp cost([%{scope: :flush}]), do: "the tick was lost before any batch was sent"

  defp cost(failures) do
    payloads = failures |> Enum.map(& &1.payloads) |> Enum.sum()
    "#{length(failures)} batch(es) and #{payloads} payload(s) lost"
  end

  # Kept to a single line. `Exception.format_banner/2` wraps some exits over
  # several lines, and a multi-line entry would put the failure count and the
  # retry interval somewhere other than the line an operator greps.
  defp format_failure(%{kind: kind, reason: reason}) do
    kind
    |> Exception.format_banner(reason)
    |> String.replace_prefix("** ", "")
    |> String.replace(~r/\s*\n\s*/, " ")
  end

  defp top_frame([entry | _]), do: Exception.format_stacktrace_entry(entry)
  defp top_frame(_), do: "an unknown location"

  defp next_flush_ms(0), do: @flush_ms

  defp next_flush_ms(consecutive_failures) do
    doublings = min(consecutive_failures - 1, @max_backoff_doublings)
    min(@flush_ms * Integer.pow(2, doublings), @max_flush_backoff_ms)
  end

  # Logs once per "dropping episode": only when this cast is what pushes the
  # key's queue over the cap for the first time (i.e. it wasn't already
  # sitting at the cap from a prior drop). This avoids logging on every cast
  # while a key stays saturated during a sustained outage.
  defp maybe_log_drop(url_key, existing, total) do
    if length(existing) < @max_queue_per_key do
      dropped = total - @max_queue_per_key

      Logger.warning(
        "[EndPointBlank] DelayedWriter queue for #{inspect(url_key)} exceeded " <>
          "#{@max_queue_per_key}; dropping #{dropped} oldest payload(s)"
      )
    end
  end

  # Arms the next tick, cancelling any tick already armed so exactly one is
  # ever outstanding. Nothing in normal operation arms two — each tick arms its
  # own successor — but `:flush` is an ordinary message, and anything that
  # sends one directly (a host app forcing a drain, a test) would otherwise
  # leave the previous timer to fire a redundant tick later and, worse, to fire
  # it ahead of a backoff that had just been extended. Enforcing the invariant
  # here is what makes "the next tick happens when the backoff says" true
  # unconditionally rather than by convention.
  defp schedule_flush(%__MODULE__{} = state, delay_ms \\ @flush_ms) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: Process.send_after(self(), :flush, delay_ms)}
  end
end
