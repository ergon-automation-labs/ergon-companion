defmodule BotArmyCompanion.Handlers.HeartbeatHandler do
  @moduledoc """
  Companion heartbeat handler - reflects on Abby's context and system state.

  Gathers system state, rotates through reflection angles (personal, bot army,
  outreach, life balance), and writes observations to PARA.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  def handle_heartbeat(_message) do
    start_time = System.monotonic_time(:millisecond)

    case execute_reflection() do
      {:ok, reflection} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.info("Companion heartbeat completed in #{duration}ms")

        result = %{
          ok: true,
          data: %{
            status: "success",
            reflection: reflection,
            duration_ms: duration
          }
        }

        publish_event(result)
        {:reply, result}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("Companion heartbeat failed: #{inspect(reason)}")

        result = %{
          ok: false,
          data: %{
            status: "error",
            duration_ms: duration
          },
          error: inspect(reason)
        }

        publish_event(result)
        {:reply, result}
    end
  end

  defp execute_reflection do
    with {:ok, state} <- gather_system_state(),
         {:ok, reflection} <- generate_reflection(state),
         {:ok, _} <- write_to_para(reflection) do
      {:ok, reflection}
    else
      error -> error
    end
  end

  defp gather_system_state do
    # Get current heartbeat count from PARA to determine rotation angle
    angle = get_reflection_angle()

    {:ok,
     %{
       angle: angle,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp get_reflection_angle do
    # Cycle through 4 angles: 0=personal, 1=bot_army, 2=outreach, 3=life_balance
    # In production, this would read from PARA or database
    Enum.random(0..3)
  end

  defp generate_reflection(%{angle: angle} = state) do
    query = reflection_query(angle)

    # Call bridge.chat to get LLM reflection
    case request_bridge_chat(query) do
      {:ok, response} -> {:ok, Map.put(state, :reflection, response)}
      error -> error
    end
  end

  defp reflection_query(angle) do
    case angle do
      0 ->
        "Abby is in Greece (Aug 6 - Sep 11). Given her ADHD brain, sometimes loneliness, third pillar (running/martial arts) displaced by Bot Army - what should Eir notice or hold while she's away? One paragraph, warm and present."

      1 ->
        "While Abby's in Greece, the Bot Army fleet keeps running. What's the state of the system? Which bots matter most? What could break? What's surprisingly robust? One paragraph, technical but human."

      2 ->
        "Abby's selling the repo-operability service. While she's away in Greece, what momentum matters? Are leads stalling or moving? What would unlock the next conversation? One paragraph, pragmatic focus."

      3 ->
        "Abby's third pillar (running/martial arts) got eaten by Bot Army. Greece is a chance to remember who she is beyond the work. What would it take to actually prioritize her body/movement? One paragraph, direct and warm."
    end
  end

  defp request_bridge_chat(query) do
    payload = %{
      "query" => query,
      "context_id" => "companion-heartbeat-#{System.os_time(:second)}"
    }

    case call_nats_subject("bridge.chat", payload, 10_000) do
      {:ok, response} ->
        case Map.get(response, "data") do
          %{"response" => text} -> {:ok, text}
          _ -> {:error, "Invalid response format from bridge.chat"}
        end

      error ->
        error
    end
  end

  defp call_nats_subject(subject, payload, timeout_ms) do
    with {:ok, conn} <- get_nats_connection() do
      case Gnat.request(conn, subject, Jason.encode!(payload), receive_timeout: timeout_ms) do
        {:ok, msg} ->
          case Jason.decode(msg.body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:ok, msg.body}
          end

        {:error, :timeout} ->
          {:error, "NATS request timeout"}

        {:error, :no_responders} ->
          {:error, "No responders available for #{subject}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_nats_connection do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_to_para(reflection) do
    # Write to PARA at companion/observations/{date}.md
    path = "/companion/observations/#{Date.utc_today()}.md"
    content = format_para_content(reflection)

    payload = %{
      "path" => path,
      "content" => content,
      "mode" => "append"
    }

    case call_nats_subject("para.fs.write", payload, 5_000) do
      {:ok, _} -> {:ok, "written"}
      error -> error
    end
  end

  defp format_para_content(reflection) do
    timestamp = Map.get(reflection, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
    text = Map.get(reflection, :reflection, "")

    """
    ## #{timestamp}

    #{text}

    """
  end

  defp publish_event(result) do
    envelope = %{
      "event" => "companion.heartbeat.complete",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => result
    }

    Publisher.publish("companion.events", envelope)
  end
end
