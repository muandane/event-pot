import Config

config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

config :k8s,
  clusters: %{
    default: %{
      conn: "~/.kube/config",
      conn_opts: []
    }
  }
