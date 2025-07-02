defmodule K8sEventWatcher.Forwarder do
  require Logger

  def test_event(type \\ :discord) do
    test_event = %{
      "type" => "Warning",
      "reason" => "CrashLoopBackOff",
      "message" => "Container 'app' in pod 'test-pod-12345' is crash looping due to exit code 1",
      "firstTimestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "namespace" => "production",
      "count" => 5,
      "involvedObject" => %{
        "kind" => "Pod",
        "name" => "test-pod-12345",
        "namespace" => "production",
        "uid" => "abc123-def456-ghi789"
      },
      "source" => %{
        "component" => "kubelet",
        "host" => "worker-node-1"
      },
      "metadata" => %{
        "name" => "test-event-#{System.system_time(:second)}",
        "uid" => "test-uid-#{System.system_time(:second)}",
        "resourceVersion" => "12345"
      }
    }

    case type do
      :discord ->
        case System.get_env("DISCORD_WEBHOOK_URL") do
          nil ->
            Logger.error("DISCORD_WEBHOOK_URL not set")
            {:error, "Discord webhook URL not configured"}
          url ->
            Logger.info("Sending test event to Discord webhook")
            send_discord_webhook(url, test_event)
        end

      :webhook ->
        case System.get_env("WEBHOOK_URL") do
          nil ->
            Logger.error("WEBHOOK_URL not set")
            {:error, "Webhook URL not configured"}
          url ->
            Logger.info("Sending test event to generic webhook")
            send_webhook(url, test_event)
        end

      :loki ->
        case System.get_env("LOKI_URL") do
          nil ->
            Logger.error("LOKI_URL not set")
            {:error, "Loki URL not configured"}
          url ->
            Logger.info("Sending test event to Loki")
            send_to_loki(url, test_event)
        end

      _ ->
        Logger.info("Testing with current configuration")
        forward_event(test_event)
    end
  end

  @webhook_url_env "WEBHOOK_URL"
  @discord_webhook_env "DISCORD_WEBHOOK_URL"
  @loki_url_env "LOKI_URL"
  @request_timeout 10_000

  def forward_event(event) do
    cond do
      discord_url = System.get_env(@discord_webhook_env) ->
        send_discord_webhook(discord_url, event)

      webhook_url = System.get_env(@webhook_url_env) ->
        send_webhook(webhook_url, event)

      loki_url = System.get_env(@loki_url_env) ->
        send_to_loki(loki_url, event)

      true ->
        Logger.warn("No forwarding destination configured (#{@discord_webhook_env}, #{@webhook_url_env}, or #{@loki_url_env})")
        :ok
    end
  end

  defp send_discord_webhook(url, event) do
    payload = build_discord_payload(event)
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, Jason.encode!(payload), headers, timeout: @request_timeout) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "Discord webhook failed - HTTP #{status}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Discord webhook request failed: #{reason}"}
    end
  end

  defp send_webhook(url, event) do
    payload = build_webhook_payload(event)
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, Jason.encode!(payload), headers, timeout: @request_timeout) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{reason}"}
    end
  end

  defp send_to_loki(url, event) do
    payload = build_loki_payload(event)
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post("#{url}/loki/api/v1/push", Jason.encode!(payload), headers, timeout: @request_timeout) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 ->
        :ok

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{reason}"}
    end
  end

  defp build_discord_payload(event) do
    involved_object = event["involvedObject"] || %{}
    namespace = event["namespace"] || "default"
    reason = event["reason"] || "Unknown"
    message = event["message"] || "No message"

    # Color based on severity
    color = case reason do
      r when r in ["CrashLoopBackOff", "Failed", "FailedMount"] -> 0xFF0000  # Red
      r when r in ["BackOff", "Unhealthy", "FailedScheduling"] -> 0xFF6600   # Orange
      r when r in ["ImagePullBackOff", "ErrImagePull"] -> 0xFFFF00          # Yellow
      _ -> 0x808080  # Gray
    end

    # Format timestamp
    timestamp = case event["firstTimestamp"] || event["eventTime"] do
      nil -> DateTime.utc_now() |> DateTime.to_iso8601()
      ts when is_binary(ts) -> ts
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end

    embed = %{
      title: "🚨 Kubernetes Event Alert",
      description: "**#{reason}** in namespace `#{namespace}`",
      color: color,
      timestamp: timestamp,
      fields: [
        %{
          name: "Object",
          value: "`#{involved_object["kind"] || "Unknown"}/#{involved_object["name"] || "Unknown"}`",
          inline: true
        },
        %{
          name: "Namespace",
          value: "`#{namespace}`",
          inline: true
        },
        %{
          name: "Reason",
          value: "`#{reason}`",
          inline: true
        },
        %{
          name: "Message",
          value: "```#{String.slice(message, 0, 1000)}```",
          inline: false
        }
      ],
      footer: %{
        text: "K8s Event Watcher",
        icon_url: "https://kubernetes.io/images/kubernetes.png"
      }
    }

    # Add count if available
    embed = if event["count"] && event["count"] > 1 do
      count_field = %{
        name: "Count",
        value: "`#{event["count"]}`",
        inline: true
      }
      %{embed | fields: [count_field | embed.fields]}
    else
      embed
    end

    %{
      embeds: [embed],
      username: "K8s Event Watcher"
    }
  end

  defp build_webhook_payload(event) do
    involved_object = event["involvedObject"] || %{}

    %{
      type: event["type"],
      reason: event["reason"],
      message: event["message"],
      timestamp: event["firstTimestamp"] || event["eventTime"],
      namespace: event["namespace"],
      involved_object: %{
        kind: involved_object["kind"],
        name: involved_object["name"],
        namespace: involved_object["namespace"],
        uid: involved_object["uid"]
      },
      source: event["source"],
      count: event["count"],
      metadata: %{
        name: get_in(event, ["metadata", "name"]),
        uid: get_in(event, ["metadata", "uid"]),
        resource_version: get_in(event, ["metadata", "resourceVersion"])
      }
    }
  end

  defp build_loki_payload(event) do
    involved_object = event["involvedObject"] || %{}
    timestamp_ns = format_timestamp_ns(event["firstTimestamp"] || event["eventTime"])

    labels = %{
      namespace: event["namespace"] || "default",
      reason: event["reason"] || "Unknown",
      object_kind: involved_object["kind"] || "Unknown",
      object_name: involved_object["name"] || "Unknown",
      source: "k8s-event-watcher"
    }

    message = build_log_message(event)

    %{
      streams: [
        %{
          stream: labels,
          values: [
            [timestamp_ns, message]
          ]
        }
      ]
    }
  end

  defp build_log_message(event) do
    involved_object = event["involvedObject"] || %{}

    "Kubernetes event: #{event["reason"]} - #{event["message"]} " <>
    "(#{involved_object["kind"]}/#{involved_object["name"]} in #{event["namespace"]})"
  end

  defp format_timestamp_ns(nil), do: to_string(System.system_time(:nanosecond))

  defp format_timestamp_ns(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> to_string(DateTime.to_unix(dt, :nanosecond))
      _ -> to_string(System.system_time(:nanosecond))
    end
  end

  defp format_timestamp_ns(_), do: to_string(System.system_time(:nanosecond))
end
