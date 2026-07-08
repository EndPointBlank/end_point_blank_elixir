defmodule EndPointBlank.Writers.DelayedWriter do
  @moduledoc """
  Background queue that batches payloads and flushes them every 100 ms.

  Payloads for each URL key are accumulated in the GenServer state and sent
  in batches of up to #{4} via `DirectWriter` on each flush tick. Batches
  (across all URL keys) are flushed concurrently, bounded by
  `EndPointBlank.Config.worker_count/0` (default 4), so a flush tick never
  fires more than that many writes in flight at once.

  Each URL key's queue is capped at #{1_000} payloads. If an intake outage
  (or any slow/hung downstream) causes payloads to accumulate faster than
  they can be flushed, the oldest payloads for that key are dropped to keep
  memory usage bounded in the host app.
  """

  use GenServer
  require Logger

  @batch_size 4
  @flush_ms 100
  @max_queue_per_key 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Enqueues `payloads` to be sent to `url_key` on the next flush."
  def write(url_key, payloads) when is_list(payloads) do
    GenServer.cast(__MODULE__, {:enqueue, url_key, payloads})
  end

  # Callbacks

  @impl true
  def init(_) do
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:enqueue, url_key, payloads}, state) do
    existing = Map.get(state, url_key, [])
    combined = existing ++ payloads
    total = length(combined)

    retained =
      if total > @max_queue_per_key do
        maybe_log_drop(url_key, existing, total)
        Enum.take(combined, -@max_queue_per_key)
      else
        combined
      end

    {:noreply, Map.put(state, url_key, retained)}
  end

  @impl true
  def handle_info(:flush, state) do
    state
    |> Enum.flat_map(fn {url_key, payloads} ->
      payloads
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(&{url_key, &1})
    end)
    |> Task.async_stream(
      fn {url_key, batch} -> EndPointBlank.Writers.DirectWriter.write(url_key, batch) end,
      max_concurrency: EndPointBlank.Config.worker_count(),
      # Http already bounds each attempt (and its retries); let it own the
      # timeout instead of racing it here.
      timeout: :infinity
    )
    |> Stream.run()

    schedule_flush()
    {:noreply, %{}}
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

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_ms)
end
