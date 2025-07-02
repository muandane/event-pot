
# mix.exs
defmodule K8sEventWatcher.MixProject do
  use Mix.Project

  def project do
    [
      app: :k8s_event_watcher,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {K8sEventWatcher.Application, []}
    ]
  end

  defp deps do
    [
      {:k8s, "~> 2.0"},
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
