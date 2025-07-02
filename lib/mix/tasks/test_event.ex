defmodule Mix.Tasks.TestEvent do
  use Mix.Task

  @shortdoc "Send a test Kubernetes event"
  @moduledoc """
  Send a test Kubernetes event to configured webhook/Discord/Loki.

  Usage:
    mix test_event            # Use current config
    mix test_event discord    # Force Discord
    mix test_event webhook    # Force generic webhook
    mix test_event loki       # Force Loki
  """

  def run(args) do
    Mix.Task.run("app.start")

    type = case args do
      ["discord"] -> :discord
      ["webhook"] -> :webhook
      ["loki"] -> :loki
      _ -> nil
    end

    case K8sEventWatcher.Forwarder.test_event(type) do
      :ok ->
        IO.puts("✅ Test event sent successfully!")
      {:error, reason} ->
        IO.puts("❌ Failed to send test event: #{reason}")
        System.halt(1)
    end
  end
end
