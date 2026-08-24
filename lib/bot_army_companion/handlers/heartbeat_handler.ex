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
    Logger.debug("execute_reflection: Starting reflection cycle")

    with {:ok, state} <- gather_system_state(),
         _ = Logger.debug("execute_reflection: gather_system_state returned: #{inspect(state)}"),
         {:ok, reflection} <- generate_reflection(state),
         _ =
           Logger.debug(
             "execute_reflection: generate_reflection returned: #{inspect(reflection)}"
           ),
         {:ok, _} <- write_to_para(reflection),
         _ = Logger.debug("execute_reflection: write_to_para completed successfully") do
      {:ok, reflection}
    else
      error ->
        Logger.error("execute_reflection: Failed with error: #{inspect(error)}")
        error
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
    # Fetch a random active thought from the database
    case BotArmyCompanion.Thoughts.get_random_active_thought() do
      {:ok, thought} -> thought.angle
      :error -> Enum.random(0..7)
    end
  end

  defp generate_reflection(%{angle: angle} = state) do
    Logger.debug("generate_reflection: Starting for angle #{angle}")

    case get_reflection_query(angle) do
      {:ok, query} ->
        Logger.debug("generate_reflection: Got query for angle #{angle}: #{inspect(query)}")

        # Fetch prior reflection context to help Companion notice loops and patterns
        case BotArmyCompanion.ReflectionHistory.summarize_prior_reflections(angle, 5) do
          {:ok, history} ->
            # Enhance the query with prior context
            enhanced_query = enhance_query_with_history(query, history)

            Logger.debug(
              "generate_reflection: Enhanced query with #{history.count} prior reflections"
            )

            case request_bridge_chat(enhanced_query) do
              {:ok, response} ->
                Logger.debug(
                  "generate_reflection: Got bridge.chat response: #{inspect(response)}"
                )

                {:ok, Map.put(state, :reflection, response)}

              error ->
                Logger.error("generate_reflection: bridge.chat failed: #{inspect(error)}")
                error
            end

          {:error, reason} ->
            Logger.warning(
              "generate_reflection: Could not fetch history (non-fatal): #{inspect(reason)}"
            )

            # Graceful degradation: proceed with original query if history fetch fails
            case request_bridge_chat(query) do
              {:ok, response} ->
                Logger.debug(
                  "generate_reflection: Got bridge.chat response: #{inspect(response)}"
                )

                {:ok, Map.put(state, :reflection, response)}

              error ->
                Logger.error("generate_reflection: bridge.chat failed: #{inspect(error)}")
                error
            end
        end

      :error ->
        Logger.error("generate_reflection: No reflection query found for angle #{angle}")
        {:error, "No reflection query found for angle #{angle}"}
    end
  end

  defp enhance_query_with_history(query, %{count: 0}) do
    # No prior reflections, use original query
    query
  end

  defp enhance_query_with_history(query, %{context: context_text, count: _count})
       when byte_size(context_text) > 0 do
    # Inject prior context into the query
    """
    #{query}

    Context from prior reflections: #{context_text}
    """
  end

  defp enhance_query_with_history(query, _history) do
    # Fallback: use original query
    query
  end

  defp get_reflection_query(angle) do
    case BotArmyCompanion.Thoughts.get_thought_by_angle(angle) do
      %{query: query} -> {:ok, query}
      nil -> :error
    end
  end

  defp request_bridge_chat(query) do
    Logger.debug("request_bridge_chat: Starting with query: #{inspect(query)}")

    payload = %{
      "query" => query,
      "context_id" => "companion-heartbeat-#{System.os_time(:second)}"
    }

    Logger.debug("request_bridge_chat: Payload: #{inspect(payload)}")

    case call_nats_subject("bridge.chat", payload, 10_000) do
      {:ok, response} ->
        Logger.debug("request_bridge_chat: Got NATS response: #{inspect(response)}")

        case Map.get(response, "data") do
          %{"response" => text} ->
            Logger.debug(
              "request_bridge_chat: Extracted text response (#{String.length(text)} chars)"
            )

            {:ok, text}

          _ ->
            Logger.error("bridge.chat unexpected response shape: #{inspect(response)}")
            {:error, "Invalid response format from bridge.chat"}
        end

      error ->
        Logger.error("bridge.chat call_nats_subject error: #{inspect(error)}")
        error
    end
  end

  defp call_nats_subject(subject, payload, timeout_ms) do
    with {:ok, conn} <- get_nats_connection() do
      handle_nats_response(
        Gnat.request(conn, subject, Jason.encode!(payload), receive_timeout: timeout_ms),
        subject
      )
    end
  end

  defp handle_nats_response({:ok, msg}, _subject) do
    case Jason.decode(msg.body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, msg.body}
    end
  end

  defp handle_nats_response({:error, :timeout}, _subject) do
    {:error, "NATS request timeout"}
  end

  defp handle_nats_response({:error, :no_responders}, subject) do
    {:error, "No responders available for #{subject}"}
  end

  defp get_nats_connection do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_to_para(reflection) do
    Logger.debug("write_to_para: Starting with reflection: #{inspect(reflection)}")

    angle = Map.get(reflection, :angle, "unknown")
    relative_path = "areas/companion/observations/#{Date.utc_today()}-angle-#{angle}.md"
    content = format_para_content(reflection)

    Logger.debug(
      "write_to_para: Path=#{relative_path}, content_size=#{String.length(content)} bytes"
    )

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => relative_path,
      "content" => content,
      "mode" => "append"
    }

    Logger.debug("write_to_para: Sending payload to para.fs.write")

    case call_nats_subject("para.fs.write", payload, 5_000) do
      {:ok, %{"ok" => false} = response} ->
        reason = Map.get(response, "error", "unknown error")
        Logger.error("para.fs.write rejected #{relative_path}: #{reason}")
        {:error, "para.fs.write rejected: #{reason}"}

      {:ok, response} ->
        Logger.info("para.fs.write succeeded for #{relative_path}: #{inspect(response)}")
        {:ok, "written"}

      error ->
        Logger.error("para.fs.write failed for #{relative_path}: #{inspect(error)}")
        error
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
