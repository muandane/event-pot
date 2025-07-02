defmodule K8sEventWatcher.EventWatcher do
  use GenServer
  require Logger

  alias K8s.Client
  alias K8s.Client.Watcher
  alias K8sEventWatcher.{Forwarder, Metrics}

  @high_severity_reasons [
    "Failed",
    "FailedMount",
    "FailedScheduling",
    "FailedSync",
    "CrashLoopBackOff",
    "BackOff",
    "Unhealthy",
    "FailedCreatePodSandBox",
    "NetworkNotReady",
    "InspectFailed",
    "ErrImageNeverPull",
    "ErrImagePull",
    "ImagePullBackOff",
    "RegistryUnavailable",
    "InvalidImageName"
  ]

  @backoff_base 1000
  @backoff_max 30000
  @watch_timeout 300

  defmodule State do
    defstruct [
      :conn,
      :watcher_pid,
      :resource_version,
      backoff_count: 0,
      last_restart: nil
    ]
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Initializing Kubernetes Event Watcher")
    send(self(), :start_watching)
    {:ok, %State{}}
  end

  @impl true
  def handle_info(:start_watching, state) do
    case setup_connection() do
      {:ok, conn} ->
        case start_watcher(conn, state.resource_version) do
          {:ok, watcher_pid, resource_version} ->
            Logger.info("Event watcher started successfully")
            new_state = %State{
              conn: conn,
              watcher_pid: watcher_pid,
              resource_version: resource_version,
              backoff_count: 0,
              last_restart: DateTime.utc_now()
            }
            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("Failed to start watcher: #{inspect(reason)}")
            schedule_restart(state.backoff_count)
            {:noreply, %{state | backoff_count: state.backoff_count + 1}}
        end

      {:error, reason} ->
        Logger.error("Failed to setup connection: #{inspect(reason)}")
        schedule_restart(state.backoff_count)
        {:noreply, %{state | backoff_count: state.backoff_count + 1}}
    end
  end

  @impl true
  def handle_info({:restart_watching, old_backoff_count}, %State{backoff_count: current_count} = state)
      when old_backoff_count == current_count do
    Logger.info("Restarting event watcher (attempt #{current_count + 1})")
    Metrics.increment(:watch_reconnections)
    send(self(), :start_watching)
    {:noreply, state}
  end

  def handle_info({:restart_watching, _old_count}, state) do
    # Ignore stale restart messages
    {:noreply, state}
  end

  @impl true
  def handle_info({:watcher_event, %{"type" => "ADDED", "object" => event}}, state) do
    handle_event(event)
    {:noreply, %{state | resource_version: event["metadata"]["resourceVersion"]}}
  end

  def handle_info({:watcher_event, %{"type" => "MODIFIED", "object" => event}}, state) do
    handle_event(event)
    {:noreply, %{state | resource_version: event["metadata"]["resourceVersion"]}}
  end

  def handle_info({:watcher_event, %{"type" => "DELETED", "object" => event}}, state) do
    Metrics.increment(:events_received)
    {:noreply, %{state | resource_version: event["metadata"]["resourceVersion"]}}
  end

  def handle_info({:watcher_event, %{"type" => "ERROR", "object" => error}}, state) do
    Logger.error("Watcher error: #{inspect(error)}")

    case error do
      %{"code" => 410} ->
        # Resource version too old, restart without resource version
        Logger.warn("Resource version expired, restarting watcher")
        schedule_restart(0)
        {:noreply, %{state | resource_version: nil, backoff_count: 0}}

      _ ->
        schedule_restart(state.backoff_count)
        {:noreply, %{state | backoff_count: state.backoff_count + 1}}
    end
  end

  def handle_info({:watcher_finished, reason}, state) do
    Logger.warn("Watcher finished: #{inspect(reason)}")
    schedule_restart(state.backoff_count)
    {:noreply, %{state | backoff_count: state.backoff_count + 1}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{watcher_pid: pid} = state) do
    Logger.warn("Watcher process died: #{inspect(reason)}")
    schedule_restart(state.backoff_count)
    {:noreply, %{state | watcher_pid: nil, backoff_count: state.backoff_count + 1}}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp setup_connection do
    try do
      conn = K8s.Conn.from_service_account()
      {:ok, conn}
    rescue
      error ->
        {:error, error}
    end
  end

  defp start_watcher(conn, resource_version) do
    operation =
      K8s.Client.list("v1", "Event")
      |> K8s.Client.put_conn(conn)

    watch_opts = [
      send_to: self(),
      timeout: @watch_timeout * 1000
    ]

    watch_opts = if resource_version do
      Keyword.put(watch_opts, :resource_version, resource_version)
    else
      watch_opts
    end

    case Watcher.start_link(operation, watch_opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        # Get initial resource version if we don't have one
        rv = resource_version || get_latest_resource_version(conn)
        {:ok, pid, rv}

      error ->
        error
    end
  end

  defp get_latest_resource_version(conn) do
    case K8s.Client.list("v1", "Event") |> K8s.Client.run(conn) do
      {:ok, %{"metadata" => %{"resourceVersion" => rv}}} -> rv
      _ -> nil
    end
  end

  defp handle_event(event) do
    Metrics.increment(:events_received)

    reason = get_in(event, ["reason"])

    if reason in @high_severity_reasons do
      Metrics.increment(:events_filtered)
      Logger.info("High severity event detected: #{reason}")

      case Forwarder.forward_event(event) do
        :ok ->
          Metrics.increment(:events_forwarded)
          Logger.debug("Successfully forwarded event: #{reason}")

        {:error, error} ->
          Metrics.increment(:forwarding_errors)
          Logger.error("Failed to forward event: #{inspect(error)}")
      end
    end
  end

  defp schedule_restart(backoff_count) do
    delay = calculate_backoff(backoff_count)
    Logger.info("Scheduling restart in #{delay}ms")
    Process.send_after(self(), {:restart_watching, backoff_count}, delay)
  end

  defp calculate_backoff(count) do
    min(@backoff_base * :math.pow(2, count), @backoff_max) |> round()
  end
end
