defmodule EndPointBlank.Writers.DelayedWriter do
  @moduledoc """
  Background queue that batches payloads and flushes them every 100 ms.

  Payloads for each URL key are accumulated in the GenServer state and sent
  in batches of up to #{4} via `DirectWriter` on each flush tick.
  """

  use GenServer
  require Logger

  @batch_size 4
  @flush_ms 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
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
    updated = Map.update(state, url_key, payloads, &(&1 ++ payloads))
    {:noreply, updated}
  end

  @impl true
  def handle_info(:flush, state) do
    Enum.each(state, fn {url_key, payloads} ->
      payloads
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(&EndPointBlank.Writers.DirectWriter.write(url_key, &1))
    end)

    schedule_flush()
    {:noreply, %{}}
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_ms)
end
