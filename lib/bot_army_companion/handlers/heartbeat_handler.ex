defmodule BotArmyCompanion.Handlers.HeartbeatHandler do
  @moduledoc """
  Companion heartbeat handler - reflects on Abby's context and system state.

  Gathers system state, rotates through reflection angles (personal, bot army,
  outreach, life balance), and writes observations to PARA.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher
  alias BotArmyCompanion.Wins
  alias BotArmyCompanion.ReflectionFormatter

  def handle_heartbeat(_message) do
    # Heartbeat should be a quick liveness check, not a heavy reflection cycle.
    # Reflections are triggered on-demand via companion.reflection endpoint.
    # Just respond immediately with basic health status.

    result = %{
      ok: true,
      data: %{
        status: "healthy"
      }
    }

    Logger.debug("Companion heartbeat responded: healthy")
    {:reply, result}
  end

  @doc "Trigger a reflection on the specified angle or a random one"
  def execute_reflection(angle \\ nil) do
    start_time = System.monotonic_time(:millisecond)

    case gather_system_state() do
      {:ok, state} ->
        # If angle not specified, use state's angle; otherwise use specified angle
        state_with_angle = if angle, do: %{state | angle: angle}, else: state

        case generate_reflection(state_with_angle) do
          {:ok, reflection} ->
            duration = System.monotonic_time(:millisecond) - start_time
            Logger.info("Companion reflection completed in #{duration}ms")

            # Persist to PARA
            write_to_para(reflection)

            {:ok, reflection}

          {:error, reason} ->
            Logger.error("Companion reflection generation failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Companion reflection state gathering failed: #{inspect(reason)}")
        {:error, reason}
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
    # Fetch a random active thought from the database.
    # Fallback to angle 0 (guaranteed to exist from seed) if database query fails.
    case BotArmyCompanion.Thoughts.get_random_active_thought() do
      {:ok, thought} -> thought.angle
      :error -> 0
    end
  end

  # Deterministic, non-LLM check: flags hardcoded date mentions (e.g. "Aug
  # 6-Sep 11") in active reflection thoughts so a stale reference doesn't sit
  # unnoticed once the event it describes has passed. Best-effort — never
  # blocks or fails the reflection cycle itself.
  defp audit_stale_dates do
    content = format_date_audit(BotArmyCompanion.Thoughts.audit_dates())

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "areas/companion/observations/stale-dates.md",
      "content" => content,
      "mode" => "write"
    }

    case call_nats_subject("para.fs.write", payload, 5_000) do
      {:ok, _} ->
        :ok

      error ->
        Logger.warning("audit_stale_dates: para.fs.write failed (non-fatal): #{inspect(error)}")
    end
  rescue
    e -> Logger.warning("audit_stale_dates: failed (non-fatal): #{inspect(e)}")
  end

  defp format_date_audit([]) do
    """
    ## Date audit — #{DateTime.utc_now() |> DateTime.to_iso8601()}

    No hardcoded dates found in active reflection thoughts.
    """
  end

  defp format_date_audit(flagged) do
    lines =
      Enum.map(flagged, fn %{angle: angle, dates: dates} ->
        "- angle #{angle}: #{Enum.join(dates, ", ")}"
      end)

    """
    ## Date audit — #{DateTime.utc_now() |> DateTime.to_iso8601()}

    Hardcoded dates found in active reflection thought seeds — verify still current
    (bot_army_companion/lib/bot_army_companion/thoughts.ex, seed_default_thoughts/0):

    #{Enum.join(lines, "\n")}
    """
  end

  defp generate_reflection(%{angle: angle} = state) do
    Logger.debug("generate_reflection: Starting for angle #{angle}")

    case get_reflection_query(angle) do
      {:ok, query} ->
        Logger.debug("generate_reflection: Got query for angle #{angle}")
        generate_reflection_with_query(state, query, angle)

      :error ->
        Logger.error("generate_reflection: No reflection query found for angle #{angle}")
        {:error, "No reflection query found for angle #{angle}"}
    end
  end

  defp generate_reflection_with_query(state, query, angle) do
    # Fetch prior reflection history
    history_res = BotArmyCompanion.ReflectionHistory.summarize_prior_reflections(angle, 5)
    # Fetch recent wins
    wins_res = Wins.fetch_recent_wins()

    history =
      case history_res do
        {:ok, h} -> h
        _ -> %{count: 0, context: ""}
      end

    wins =
      case wins_res do
        wins when is_list(wins) -> wins
        _ -> []
      end

    enhanced_query = enhance_query_with_context(query, history, wins)

    Logger.debug(
      "generate_reflection: Enhanced query with #{history.count} prior reflections and #{length(wins)} wins"
    )

    generate_reflection_from_query(state, enhanced_query)
  end

  defp generate_reflection_from_query(state, query) do
    case request_bridge_chat(query) do
      {:ok, response} ->
        Logger.debug("generate_reflection: Got bridge.chat response")
        {:ok, Map.put(state, :reflection, response)}

      error ->
        Logger.error("generate_reflection: bridge.chat failed: #{inspect(error)}")
        error
    end
  end

  defp enhance_query_with_context(query, history, wins) do
    context_parts = []

    context_parts =
      if history.count > 0 and byte_size(history.context) > 0 do
        ["Prior reflections context: #{history.context}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if length(wins) > 0 do
        wins_text = Enum.map_join(wins, "\n", fn win -> "• #{win}" end)
        ["Recent wins: #{wins_text}" | context_parts]
      else
        context_parts
      end

    if Enum.empty?(context_parts) do
      query
    else
      """
      #{query}

      Context for reflection:
      #{Enum.join(context_parts, "\n\n")}
      """
    end
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

    case call_nats_subject("bridge.chat", payload, 35_000) do
      {:ok, response} ->
        Logger.debug("request_bridge_chat: Got NATS response: #{inspect(response)}")

        # Handle both sync (direct response) and async (job_id) responses
        case response do
          %{"data" => %{"response" => text}} ->
            # Synchronous response (legacy)
            Logger.debug(
              "request_bridge_chat: Extracted text response (#{String.length(text)} chars)"
            )

            {:ok, text}

          %{"job_id" => job_id, "status" => "accepted"} ->
            # Asynchronous response - poll for results
            Logger.debug("request_bridge_chat: Got async job_id=#{job_id}, polling for results")
            poll_job_result(job_id, 0, 60)

          _ ->
            Logger.error("bridge.chat unexpected response shape: #{inspect(response)}")
            {:error, "Invalid response format from bridge.chat"}
        end

      error ->
        Logger.error("bridge.chat call_nats_subject error: #{inspect(error)}")
        error
    end
  end

  # Poll for job completion (up to 60 seconds, checking every second)
  defp poll_job_result(_job_id, attempt, max_attempts) when attempt >= max_attempts do
    Logger.error("poll_job_result: Timeout waiting for job after #{max_attempts}s")
    {:error, "Job timeout: LLM response took too long"}
  end

  defp poll_job_result(job_id, attempt, max_attempts) do
    # Wait 1 second before polling (except on first attempt)
    if attempt > 0 do
      Process.sleep(1000)
    end

    payload = %{"job_id" => job_id}

    case call_nats_subject("bridge.job.status", payload, 5_000) do
      {:ok, %{"ok" => true, "status" => "completed", "result" => result}} ->
        Logger.debug("poll_job_result: Job completed after #{attempt + 1}s")
        extract_result_text(result)

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.error("poll_job_result: Job error: #{error}")
        {:error, "Job failed: #{error}"}

      {:ok, %{"status" => "pending"}} ->
        Logger.debug(
          "poll_job_result: Job still pending (attempt #{attempt + 1}/#{max_attempts})"
        )

        poll_job_result(job_id, attempt + 1, max_attempts)

      error ->
        Logger.error("poll_job_result: Status check error: #{inspect(error)}")
        # Retry on error
        poll_job_result(job_id, attempt + 1, max_attempts)
    end
  end

  # Extract text from various result formats
  defp extract_result_text(%{"response" => text}) when is_binary(text), do: {:ok, text}

  defp extract_result_text(%{"data" => %{"response" => text}}) when is_binary(text),
    do: {:ok, text}

  defp extract_result_text(text) when is_binary(text), do: {:ok, text}

  defp extract_result_text(result) do
    Logger.error("extract_result_text: Unexpected result format: #{inspect(result)}")
    {:error, "Invalid result format from job"}
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
    timestamp = Map.get(reflection, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    # Use new formatter with tags and wikilinks, fallback if it fails
    formatted_content =
      case ReflectionFormatter.format_reflection(reflection) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Logger.warning("Formatter failed: #{reason}, using plain format")
          "## #{timestamp}\n\n#{Map.get(reflection, :reflection, "")}\n"
      end

    # Updated path: areas/Companion/reflections/YYYY-MM-DD_angle_title.md
    relative_path = "areas/Companion/reflections/#{Date.utc_today()}_#{angle}_reflection.md"
    content = formatted_content

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

    # First try the local NATS connection (works if on air or if leafnode routes properly)
    case call_nats_subject("para.fs.write", payload, 5_000) do
      {:ok, %{"ok" => false} = response} ->
        reason = Map.get(response, "error", "unknown error")
        Logger.error("para.fs.write rejected #{relative_path}: #{reason}")
        {:error, "para.fs.write rejected: #{reason}"}

      {:ok, response} ->
        Logger.info("para.fs.write succeeded for #{relative_path}: #{inspect(response)}")
        {:ok, "written"}

      {:error, "No responders available for para.fs.write"} ->
        # If on mini and PARA not found, try connecting to air's NATS directly
        Logger.info("para.fs.write: No responders on local NATS, trying air's NATS")
        call_para_on_air(payload, relative_path)

      error ->
        Logger.error("para.fs.write failed for #{relative_path}: #{inspect(error)}")
        error
    end
  end

  defp call_para_on_air(payload, relative_path) do
    # Connect to air's NATS via Tailscale (mini and air are on separate NATS clusters)
    # Air's Tailscale IP is configured in the pillar (air_tailscale_ip)
    air_host = BotArmyLibraryRuntime.ConfigLoader.get("AIR_TAILSCALE_IP", "100.90.128.89")

    Logger.info("para.fs.write: Connecting to air's NATS at #{air_host}:4222")

    case Gnat.start_link(name: :para_air_conn, host: air_host, port: 4222) do
      {:ok, conn} ->
        result =
          Gnat.request(conn, "para.fs.write", Jason.encode!(payload), receive_timeout: 5_000)

        Gnat.close(conn)

        case result do
          {:ok, msg} ->
            case Jason.decode(msg.body) do
              {:ok, response} ->
                if Map.get(response, "ok", false) do
                  Logger.info("para.fs.write succeeded via air NATS for #{relative_path}")
                  {:ok, "written"}
                else
                  reason = Map.get(response, "error", "unknown error")
                  Logger.error("para.fs.write rejected via air: #{reason}")
                  {:error, "para.fs.write rejected: #{reason}"}
                end

              {:error, _} ->
                Logger.info("para.fs.write succeeded via air NATS for #{relative_path}")
                {:ok, "written"}
            end

          {:error, :timeout} ->
            {:error, "para.fs.write timeout via air NATS"}

          {:error, reason} ->
            {:error, "para.fs.write failed via air NATS: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("Could not connect to air's NATS for para.fs.write: #{inspect(reason)}")
        {:error, "Could not reach PARA on air"}
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
