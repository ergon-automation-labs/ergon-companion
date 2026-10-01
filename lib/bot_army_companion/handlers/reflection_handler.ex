defmodule BotArmyCompanion.Handlers.ReflectionHandler do
  @moduledoc """
  Companion reflection handler - reflects on Abby's context and system state.

  Gathers system state, rotates through reflection angles (personal, bot army,
  outreach, life balance), and writes observations to PARA.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher
  alias BotArmyCompanion.JobStatus
  alias BotArmyCompanion.Private
  alias BotArmyCompanion.Wins
  alias BotArmyCompanion.ReflectionFormatter

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
            Logger.error("Companion reflection generation failed: #{Private.describe(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Companion reflection state gathering failed: #{Private.describe(reason)}")
        {:error, reason}
    end
  end

  defp gather_system_state do
    # Gather comprehensive context for reflection: bot health, tasks, friction, calendar, inbox
    angle = get_reflection_angle()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Fetch context in parallel (non-blocking)
    bot_health = fetch_bot_health()
    active_tasks = fetch_active_tasks()
    friction_summary = fetch_friction_summary(7)
    calendar_events = fetch_calendar_events()
    inbox_status = fetch_inbox_status()
    daily_log = fetch_recent_daily_log()
    adventure_log = fetch_adventure_log()

    {:ok,
     %{
       angle: angle,
       timestamp: timestamp,
       bot_health: bot_health,
       active_tasks: active_tasks,
       friction_summary: friction_summary,
       calendar_events: calendar_events,
       inbox_status: inbox_status,
       daily_log: daily_log,
       adventure_log: adventure_log
     }}
  end

  defp fetch_bot_health do
    # Fetch bot health snapshot from bridge or registry
    case call_nats_subject("bot.army.registry.query", %{"service" => "all"}, 3_000) do
      {:ok, %{"data" => %{"bots" => bots}}} ->
        unhealthy =
          bots
          |> Enum.filter(fn bot -> bot["status"] != "healthy" end)
          |> Enum.map(fn bot -> "#{bot["name"]}: #{bot["status"]}" end)

        case unhealthy do
          [] -> "All bots healthy"
          issues -> "Issues: #{Enum.join(issues, "; ")}"
        end

      _ ->
        "Bot health: unavailable"
    end
  rescue
    _ -> "Bot health: error fetching"
  end

  defp fetch_active_tasks do
    # Fetch active GTD tasks to understand what you're working on
    case call_nats_subject("bridge.task.list", %{"status" => "active"}, 5_000) do
      {:ok, %{"data" => %{"tasks" => tasks}}} ->
        count = length(tasks)

        top_3 =
          tasks
          |> Enum.take(3)
          |> Enum.map(fn t -> "• #{t["title"]}" end)
          |> Enum.join("\n")

        "Active tasks: #{count}\nTop priorities:\n#{top_3}"

      _ ->
        "Active tasks: unavailable"
    end
  rescue
    _ -> "Active tasks: error fetching"
  end

  defp fetch_friction_summary(days) do
    # Fetch friction points from last N days to understand system pain
    case call_nats_subject("system.friction.summary", %{"days" => days}, 3_000) do
      {:ok, %{"data" => %{"summary" => summary}}} ->
        top_3 =
          summary
          |> Enum.take(3)
          |> Enum.map(fn f -> "• #{f["reason"]}: #{f["count"]}x" end)
          |> Enum.join("\n")

        "Top friction (#{days}d): #{Enum.sum(Map.values(summary))}\n#{top_3}"

      _ ->
        "Friction: unavailable"
    end
  rescue
    _ -> "Friction: error fetching"
  end

  defp fetch_calendar_events do
    # Fetch upcoming calendar events to understand what's coming
    case call_nats_subject("calendar.events.upcoming", %{"days" => 14}, 3_000) do
      {:ok, %{"data" => %{"events" => events}}} ->
        count = length(events)
        next_event = List.first(events)

        if next_event do
          "Calendar: #{count} events upcoming\nNext: #{next_event["title"]} (#{next_event["date"]})"
        else
          "Calendar: empty"
        end

      _ ->
        "Calendar: unavailable"
    end
  rescue
    _ -> "Calendar: error fetching"
  end

  defp fetch_inbox_status do
    # Fetch inbox to understand communication backlog
    case call_nats_subject("inbox.status", %{}, 3_000) do
      {:ok, %{"data" => %{"count" => count, "oldest_age_hours" => age}}} ->
        if count > 0 do
          "Inbox: #{count} waiting (oldest: #{age}h old)"
        else
          "Inbox: clear"
        end

      _ ->
        "Inbox: unavailable"
    end
  rescue
    _ -> "Inbox: error fetching"
  end

  defp fetch_recent_daily_log do
    # Fetch today's and yesterday's daily log entries to see what actually got done
    case call_nats_subject(
           "para.fs.read",
           %{"relative_path" => "projects/Bot Army/progress/DAILY_LOG.md"},
           3_000
         ) do
      {:ok, %{"data" => %{"content" => content}}} ->
        # Extract today's section (most recent entries)
        lines = String.split(content, "\n")

        today_entries =
          lines
          |> Enum.filter(fn line -> String.starts_with?(line, "- ") end)
          |> Enum.take(5)
          |> Enum.join("\n")

        if byte_size(today_entries) > 0 do
          "Recent progress:\n#{today_entries}"
        else
          "Daily log: no recent entries"
        end

      _ ->
        "Daily log: unavailable"
    end
  rescue
    _ -> "Daily log: unavailable"
  end

  # --- The party's adventures ---

  # Where the table lives: the same two questions the party phone asks, so the
  # reflection and the screen see one table and not two.
  @adventure_sessions_subject "rpg.session.list"
  @adventure_window_subject "rpg.session.gather_context"

  # Bounded so one long table cannot become the whole prompt: the newest turns,
  # each trimmed to a readable line.
  @adventure_turns 5
  @adventure_turn_chars 300

  # What the party angle reflects on: what the table is, who is at it, and what
  # happened there. Read from the running window rather than from the GTD tasks the
  # party is made of, so the reflection is about the play and not about the plan.
  defp fetch_adventure_log do
    case call_nats_subject(@adventure_sessions_subject, %{}, 5_000) do
      {:ok, reply} ->
        adventure_log(reply, fn body ->
          call_nats_subject(@adventure_window_subject, body, 5_000)
        end)

      _ ->
        "Adventures: unavailable"
    end
  rescue
    _ -> "Adventures: unavailable"
  end

  @doc """
  The adventure log, built from the session list's raw answer and a reader for the
  window's raw answer.

  Public and pure so the honesty rules are pinned by tests instead of by hope. There
  are three different nothings here and they are not interchangeable: no window has
  been opened (a fact), a window that could not be read (a refusal), and a window with
  nothing written at the table (a fact — an empty table is not a missing one).
  """
  def adventure_log({:ok, %{"data" => %{"sessions" => sessions}}}, read_window)
      when is_list(sessions) do
    case adventure_window(sessions) do
      {:ok, session} ->
        session
        |> adventure_lines(read_window.(%{"session_id" => session["id"]}))
        |> Enum.join("\n")

      :none ->
        "Adventures: no window has been opened yet"
    end
  end

  def adventure_log(_list_reply, _read_window), do: "Adventures: unavailable"

  # The window to reflect on: the one that is open, or else the one most recently
  # touched. Both timestamps are ISO-8601, so the newest is the largest string.
  defp adventure_window(sessions) do
    case Enum.find(sessions, &(&1["status"] == "active")) do
      nil ->
        sessions
        |> Enum.filter(&is_binary(&1["id"]))
        |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
        |> List.first()
        |> case do
          nil -> :none
          session -> {:ok, session}
        end

      session ->
        {:ok, session}
    end
  end

  defp adventure_lines(session, window) do
    ["Adventures: #{adventure_head(session, window)}", party_line(window), turns_line(window)]
  end

  defp adventure_head(session, {:ok, %{"data" => data}}) when is_map(data) do
    "#{describe_scene(session)}, #{status_of(session)}, #{turn_phrase(data["scene_facts"])}"
  end

  defp adventure_head(session, _unreadable) do
    "#{describe_scene(session)}, #{status_of(session)} — the window could not be read, " <>
      "so its turns are unreported"
  end

  defp describe_scene(session) do
    case session["scene_description"] do
      scene when is_binary(scene) and scene != "" -> "\"#{scene}\""
      _unnamed -> "an unnamed scene"
    end
  end

  defp status_of(session), do: session["status"] || "status unreported"

  defp turn_phrase(facts) when is_list(facts), do: "#{length(facts)} turns at the table"

  defp turn_phrase(_unreported), do: "an unreported number of turns at the table"

  defp party_line({:ok, %{"data" => data}}) when is_map(data), do: party_line(data["party"])
  defp party_line({:ok, _other}), do: "The roster was not in the answer."

  defp party_line(%{"members" => members}) when is_list(members), do: members_line(members)
  defp party_line(%{"members" => _unreported}), do: "The roster could not be read."

  defp party_line(party) when is_map(party) and map_size(party) == 0,
    do: "She walks with no one yet."

  defp party_line(nil), do: "The roster could not be read."
  defp party_line(_unreadable), do: "The roster could not be read."

  defp members_line([]), do: "She walks with no one yet."

  defp members_line(members) do
    case members |> Enum.map(&member_name/1) |> Enum.reject(&is_nil/1) do
      [] -> "She walks with #{length(members)} companions the roster does not name."
      names -> "She walks with #{Enum.join(names, ", ")}."
    end
  end

  defp member_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp member_name(_unnamed), do: nil

  defp turns_line({:ok, %{"data" => %{"scene_facts" => facts}}}) when is_list(facts),
    do: turns_line(facts)

  defp turns_line({:ok, %{"data" => data}}) when is_map(data),
    do: "The table's turns were not in the answer."

  defp turns_line([]), do: "Nothing has been written at the table yet."

  defp turns_line(facts) when is_list(facts) do
    case facts
         |> Enum.take(@adventure_turns)
         |> Enum.map(&trim_turn/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> "Nothing has been written at the table yet."
      turns -> "Recently at the table:\n#{Enum.map_join(turns, "\n", &"• #{&1}")}"
    end
  end

  defp turns_line(_unreadable), do: "The table's turns could not be read."

  defp trim_turn(turn) when is_binary(turn), do: String.slice(turn, 0, @adventure_turn_chars)
  defp trim_turn(_not_text), do: ""

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
        Logger.warning(
          "audit_stale_dates: para.fs.write failed (non-fatal): #{Private.describe(error)}"
        )
    end
  rescue
    e -> Logger.warning("audit_stale_dates: failed (non-fatal): #{Private.describe(e)}")
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

    # Pass system state for rich context
    system_state = Map.drop(state, [:angle, :timestamp])
    enhanced_query = enhance_query_with_context(query, history, wins, system_state)

    Logger.debug(
      "generate_reflection: Enhanced query with #{history.count} prior reflections, #{length(wins)} wins, and system context"
    )

    generate_reflection_from_query(state, enhanced_query)
  end

  defp generate_reflection_from_query(state, query) do
    case request_bridge_chat(query) do
      {:ok, response} ->
        Logger.debug("generate_reflection: Got bridge.chat response")

        # The bridge returns a canned response (not an error) when its LLM service
        # is unavailable — catch it here so we never persist "I'm not available
        # right now" as a reflection (happened 2026-09-02 15:56).
        if llm_unavailable_response?(response) do
          Logger.warning(
            "generate_reflection: bridge returned LLM-unavailable canned response — skipping reflection"
          )

          {:error, "LLM service unavailable"}
        else
          {:ok, Map.put(state, :reflection, response)}
        end

      error ->
        Logger.error("generate_reflection: bridge.chat failed: #{inspect(error)}")
        error
    end
  end

  defp enhance_query_with_context(query, history, wins, system_state \\ %{}) do
    context_parts = []

    # Add system state context
    context_parts =
      if system_state[:bot_health] do
        ["System State:\n#{system_state[:bot_health]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:active_tasks] do
        ["#{system_state[:active_tasks]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:friction_summary] do
        ["#{system_state[:friction_summary]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:calendar_events] do
        ["#{system_state[:calendar_events]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:inbox_status] do
        ["#{system_state[:inbox_status]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:daily_log] do
        ["#{system_state[:daily_log]}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if system_state[:adventure_log] do
        ["#{system_state[:adventure_log]}" | context_parts]
      else
        context_parts
      end

    # Add prior reflections and wins (existing context)
    context_parts =
      if history.count > 0 and byte_size(history.context) > 0 do
        ["Prior reflection patterns: #{history.context}" | context_parts]
      else
        context_parts
      end

    context_parts =
      if length(wins) > 0 do
        wins_text = Enum.map_join(wins, "\n", fn win -> "• #{win}" end)
        ["Recent wins this week: #{wins_text}" | context_parts]
      else
        context_parts
      end

    if Enum.empty?(context_parts) do
      query
    else
      """
      #{query}

      Current situation:
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

  # Matches the canned response ClaudeBridge.ChatResponder emits when its LLM
  # service is unavailable (chat_responder.ex) — see generate_reflection_from_query.
  defp llm_unavailable_response?(text) when is_binary(text) do
    String.contains?(text, "I'm not available right now")
  end

  defp llm_unavailable_response?(_), do: false

  defp request_bridge_chat(query) do
    Logger.debug("request_bridge_chat: starting (#{Private.describe(query)})")

    payload = %{
      "query" => query,
      "context_id" => "companion-heartbeat-#{System.os_time(:second)}"
    }

    Logger.debug("request_bridge_chat: payload (#{Private.describe(payload)})")

    case call_nats_subject("bridge.chat", payload, 35_000) do
      {:ok, response} ->
        Logger.debug("request_bridge_chat: got a response (#{Private.describe(response)})")

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
            Logger.error("bridge.chat unexpected response shape: #{Private.describe(response)}")

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
      {:ok, reply} -> job_status_step(reply, job_id, attempt, max_attempts)
      error -> retry_job_status(error, job_id, attempt, max_attempts)
    end
  end

  # What a status reply *means* is not decided here: `JobStatus` owns the words,
  # because the bridge says `processing` where the llm bot says `pending`, and
  # reading one bot's vocabulary against the other bot's replies is what failed
  # this lane (2026-10-01 06:02) — a running job logged as an error, once a
  # second, until the reflection gave up on work that was being done.
  defp job_status_step(reply, job_id, attempt, max_attempts) do
    case JobStatus.step(reply) do
      {:done, result} ->
        Logger.debug("poll_job_result: Job completed after #{attempt + 1}s")
        extract_result_text(result)

      {:failed, error} ->
        Logger.error("poll_job_result: Job error: #{Private.describe(error)}")
        {:error, "Job failed: #{Private.describe(error)}"}

      :wait ->
        Logger.debug(
          "poll_job_result: Job still running (attempt #{attempt + 1}/#{max_attempts})"
        )

        poll_job_result(job_id, attempt + 1, max_attempts)

      :missing ->
        Logger.error("poll_job_result: the bridge does not know job #{job_id}")
        {:error, "Job failed: the bridge does not know that job"}

      :unreadable ->
        retry_job_status(reply, job_id, attempt, max_attempts)
    end
  end

  defp retry_job_status(reason, job_id, attempt, max_attempts) do
    Logger.error("poll_job_result: Status check error: #{Private.describe(reason)}")
    # Retry on error
    poll_job_result(job_id, attempt + 1, max_attempts)
  end

  # Extract text from various result formats
  defp extract_result_text(%{"response" => text}) when is_binary(text), do: {:ok, text}

  defp extract_result_text(%{"data" => %{"response" => text}}) when is_binary(text),
    do: {:ok, text}

  defp extract_result_text(text) when is_binary(text), do: {:ok, text}

  defp extract_result_text(result) do
    Logger.error("extract_result_text: Unexpected result format: #{Private.describe(result)}")
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

  defp handle_nats_response({:ok, msg}, subject) do
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
    Logger.debug("write_to_para: formatting a reflection (#{Private.describe(reflection)})")

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
        Logger.info(
          "para.fs.write succeeded for #{relative_path} (#{Private.describe(response)})"
        )

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
