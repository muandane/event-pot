defmodule K8sEventWatcher.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      K8sEventWatcher.Metrics,
      K8sEventWatcher.EventWatcher
    ]

    opts = [strategy: :one_for_one, name: K8sEventWatcher.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# lib/k8s_event_watcher/metrics.ex
defmodule K8sEventWatcher.Metrics do
  use GenServer
  require Logger

  @metrics [
    :events_received,
    :events_filtered,
    :events_forwarded,
    :watch_reconnections,
    :forwarding_errors
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def increment(metric) when metric in @metrics do
    GenServer.cast(__MODULE__, {:increment, metric})
  end

  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @impl true
  def init(_) do
    metrics = Map.new(@metrics, &{&1, 0})
    Logger.info("Metrics initialized: #{inspect(Map.keys(metrics))}")
    {:ok, metrics}
  end

  @impl true
  def handle_cast({:increment, metric}, state) do
    {:noreply, Map.update!(state, metric, &(&1 + 1))}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state, state}
  end
end
