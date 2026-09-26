defmodule BotArmyCompanion.NATS.Consumer do
  @moduledoc """
  NATS message consumer for companion.

  Subscribes to NATS subjects and routes messages to handlers.
  Uses standardized Reply format for request/reply patterns.

  All request/reply handlers should return responses using Reply helpers:
  - Reply.ok(data) for success
  - Reply.error(message, code) for errors
  """

  use GenServer
  require Logger

  alias BotArmyCompanion.Reflections
  alias BotArmyLibraryRuntime.NATS.Reply

  @reconnect_delay_ms 5000
  @heartbeat_interval_ms 30_000
  @version Mix.Project.config()[:version]

  # Register subjects with their metadata for runtime discovery
  @subjects [
    %{
      subject: "companion.heartbeat",
      type: :request_reply,
      description: "Quick liveness check - just responds healthy"
    },
    %{
      subject: "companion.reflection",
      type: :request_reply,
      description: "Trigger a reflection on a specific angle or default (on-demand)"
    },
    %{
      subject: "companion.observations.list",
      type: :request_reply,
      description: "List recent PARA observations (reflections), newest first"
    },
    %{
      subject: "companion.observations.read",
      type: :request_reply,
      description: "Read one observation's full content by filename"
    },
    %{
      subject: "companion.observations.reply",
      type: :request_reply,
      description: "Append Abby's reply to an observation"
    },
    %{
      subject: "companion.presence",
      type: :pubsub,
      description: "Witness system publishes Eir's chimes (post-tool hook events)"
    },
    %{
      subject: "companion.reflections.capture",
      type: :request_reply,
      description: "Store one reflection she wrote on a reflect screen"
    },
    %{
      subject: "companion.reflections.list",
      type: :request_reply,
      description: "List her captured reflections, newest first"
    },
    %{
      subject: "companion.reflections.read",
      type: :request_reply,
      description: "Read one of her captured reflections by id"
    },
    %{
      subject: "events.reflection.captured",
      type: :pubsub,
      description: "Reflections captured on the dashboard reflect screens (stored on arrival)"
    }
  ]

  @doc """
  Every subject this consumer advertises, as registered for discovery.

  Public so a test can assert what the floor subscribes to without starting a
  broker: the two reflect screens used to publish into a subject that nothing
  listened to, and "something is listening" is exactly what went wrong.
  """
  def subjects, do: @subjects

  @doc """
  The subjects a primary node subscribes to on connect.

  Derived from `subjects/0` rather than written out a second time, so a subject
  cannot be advertised and never subscribed to (or the reverse).
  """
  def business_subjects, do: Enum.map(@subjects, & &1.subject)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("Starting NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts,
      # LeaderElection announces the real role shortly after startup; defaulting
      # to standby means a not-yet-elected node never answers business traffic.
      role: :standby
    }

    send(self(), :heartbeat)

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        handle_nats_connected(conn, state)

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp handle_nats_connected(conn, state) do
    BotArmyLibraryRuntime.NATS.Connection.subscribe_to_status()
    state = %{state | conn: conn}

    if state.role == :primary do
      subscribe_business_subjects(state)
    else
      Logger.info("Companion consumer standby — not subscribing to business subjects")
      {:noreply, register_with_role(%{state | subscriptions: []})}
    end
  end

  defp subscribe_business_subjects(state) do
    Logger.info("Connected to NATS, subscribing to topics")

    subscriptions =
      business_subjects()
      |> Enum.map(&subscribe_to_subject(state.conn, &1))
      |> Enum.filter(&(not is_nil(&1)))

    {:noreply, register_with_role(%{state | subscriptions: subscriptions})}
  end

  @doc """
  Called by `BotArmyLibraryRuntime.LeaderElection`'s `on_role_change` callback.
  """
  def leader_role_changed(role) when role in [:primary, :standby] do
    GenServer.cast(__MODULE__, {:leader_role_changed, role})
  end

  @impl true
  def handle_cast({:leader_role_changed, :primary}, %{conn: nil} = state) do
    Logger.warning(
      "Companion consumer designated PRIMARY, but NATS not connected yet — will subscribe once connected"
    )

    {:noreply, %{state | role: :primary}}
  end

  def handle_cast({:leader_role_changed, :primary}, %{subscriptions: []} = state) do
    Logger.warning("Companion consumer becoming PRIMARY — subscribing to business subjects")
    subscribe_business_subjects(%{state | role: :primary})
  end

  def handle_cast({:leader_role_changed, :primary}, state) do
    {:noreply, %{state | role: :primary}}
  end

  def handle_cast({:leader_role_changed, :standby}, state) do
    Logger.warning("Companion consumer becoming STANDBY — unsubscribing from business subjects")

    if state.conn do
      Enum.each(state.subscriptions, &Gnat.unsub(state.conn, &1))
    end

    {:noreply, register_with_role(%{state | role: :standby, subscriptions: []})}
  end

  # Registers with the fleet Registry, reflecting the current role in
  # deployment_status so a standby node is visible but clearly not serving.
  defp register_with_role(state) do
    deployment_status = if state.role == :primary, do: "deployed", else: "standby"
    BotArmyLibraryRuntime.Registry.register("companion", @subjects, @version, deployment_status)
    state
  end

  defp subscribe_to_subject(conn, subject) do
    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        Logger.info("Subscribed to #{subject}")
        sub

      {:error, reason} ->
        Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
        nil
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyLibraryRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.info(
        "DEBUG: Received NATS message on subject: #{msg.topic}, reply_to=#{inspect(Map.get(msg, :reply_to))}"
      )

      # Two subjects arrive as bare JSON rather than an event envelope:
      # companion.presence (witness chimes) and events.reflection.captured (her
      # words, straight off the reflect screens).
      case msg.topic do
        "companion.presence" ->
          handle_presence_update(msg)

        "events.reflection.captured" ->
          handle_reflection_captured(msg)

        _other ->
          process_message(msg)
      end
    end)

    {:noreply, state}
  end

  defp process_message(msg) do
    if msg.reply_to do
      Logger.info(
        "DEBUG: process_message received request/reply on #{msg.topic}, reply_to=#{msg.reply_to}"
      )

      handle_request_reply(msg)
    else
      Logger.info("DEBUG: process_message received pub/sub on #{msg.topic}")
      handle_pubsub(msg)
    end
  end

  defp handle_request_reply(msg) do
    case msg.topic do
      "companion.heartbeat" ->
        handle_heartbeat_request(msg)

      "companion.reflection" ->
        handle_reflection_request(msg)

      "companion.observations.list" ->
        handle_observations_list_request(msg)

      "companion.observations.read" ->
        handle_observations_read_request(msg)

      "companion.observations.reply" ->
        handle_observations_reply_request(msg)

      # The reflection verbs arrive under one prefix and dispatch through a
      # single clause, so this reply table stays flat as they are added.
      "companion.reflections." <> _ ->
        handle_reflections_request(msg)

      _ ->
        Logger.debug("Unknown request/reply subject: #{msg.topic}")
    end
  end

  defp handle_heartbeat_request(msg) do
    Logger.info("DEBUG: handle_heartbeat_request called, reply_to=#{msg.reply_to}")

    response =
      case BotArmyCompanion.Handlers.HeartbeatHandler.handle_heartbeat(msg.body) do
        {:reply, %{ok: true, data: data}} ->
          Reply.ok(data)

        {:reply, %{ok: false, data: data, error: reason}} ->
          # Handler includes both data (status/duration) and error message
          Reply.error(
            %{"data" => data, "error" => reason},
            :heartbeat_failed
          )

        {:reply, result} ->
          # Fallback for any other reply format
          Logger.warning("Unexpected heartbeat handler response format: #{inspect(result)}")
          Reply.error("Unexpected response format", :internal_error)
      end

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        # Reply.ok/1 already returns a JSON-encoded string — publish it as-is.
        # Double-encoding here (Jason.encode! of the string) sent a JSON string
        # literal on the wire; consumers that decode the body then got a bare
        # string instead of an object (this crashed the job scheduler's check
        # loop at 2026-09-12 03:00 EEST and skipped the reflection slot).
        Gnat.pub(conn, msg.reply_to, response)

      {:error, reason} ->
        Logger.warning(
          "Failed to get NATS connection to reply to companion.heartbeat: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.error("Error handling companion.heartbeat request: #{inspect(e)}")
  end

  defp handle_reflection_request(msg) do
    Logger.info("DEBUG: handle_reflection_request called, reply_to=#{msg.reply_to}")

    # Start reflection in background, return job_id immediately (async pattern)
    job_id = UUID.uuid4()
    Task.start(fn -> execute_reflection_task(job_id) end)

    response =
      Reply.ok(%{
        "job_id" => job_id,
        "status" => "accepted",
        "note" =>
          "Reflection running in background. Poll companion.reflection.status to check progress."
      })

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        # Reply.ok/1 already returns a JSON-encoded string — publish as-is
        # (same double-encode bug as the heartbeat handler; see comment there).
        Gnat.pub(conn, msg.reply_to, response)

      {:error, reason} ->
        Logger.warning(
          "Failed to get NATS connection to reply to companion.reflection: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.error("Error handling companion.reflection request: #{inspect(e)}")
  end

  defp execute_reflection_task(job_id) do
    Logger.info("Reflection task #{job_id} starting...")

    case BotArmyCompanion.Handlers.ReflectionHandler.execute_reflection() do
      {:ok, reflection} ->
        Logger.info("Reflection task #{job_id} completed successfully")

      {:error, reason} ->
        Logger.error("Reflection task #{job_id} failed: #{inspect(reason)}")
    end
  end

  defp handle_observations_list_request(msg) do
    limit = decode_body(msg.body) |> Map.get("limit", 20)

    response =
      case BotArmyCompanion.Handlers.ObservationsHandler.list_observations(limit) do
        {:ok, observations} ->
          Reply.ok(%{"observations" => observations})

        {:error, reason} ->
          Reply.error(inspect(reason), :list_failed)
      end

    reply(msg, response)
  rescue
    e ->
      Logger.error("Error handling companion.observations.list request: #{inspect(e)}")
  end

  defp handle_observations_read_request(msg) do
    body = decode_body(msg.body)

    response =
      case Map.get(body, "filename") do
        filename when is_binary(filename) ->
          case BotArmyCompanion.Handlers.ObservationsHandler.read_observation(filename) do
            {:ok, content} ->
              Reply.ok(%{"filename" => filename, "content" => content})

            {:error, reason} ->
              Reply.error(inspect(reason), :read_failed)
          end

        _ ->
          Reply.error("Missing 'filename'", :bad_request)
      end

    reply(msg, response)
  rescue
    e ->
      Logger.error("Error handling companion.observations.read request: #{inspect(e)}")
  end

  defp handle_observations_reply_request(msg) do
    body = decode_body(msg.body)
    filename = Map.get(body, "filename")
    reply_text = Map.get(body, "reply")

    response =
      case BotArmyCompanion.Handlers.ObservationsHandler.reply_to_observation(
             filename,
             reply_text
           ) do
        {:ok, _} ->
          Reply.ok(%{"filename" => filename})

        {:error, reason} ->
          Reply.error(inspect(reason), :reply_failed)
      end

    reply(msg, response)
  rescue
    e ->
      Logger.error("Error handling companion.observations.reply request: #{inspect(e)}")
  end

  # --- her captured reflections ----------------------------------------------

  # Her words arrive on a subject that had no subscriber at all until now: the
  # two reflect screens published them and core NATS dropped them, while the
  # screen said "captured". Storing them is the whole point of this
  # subscription. Her text is never logged — the line carries the id and the
  # length, nothing else.
  defp handle_reflection_captured(msg) do
    case Jason.decode(msg.body) do
      {:ok, payload} ->
        case store_reflection(payload) do
          {:ok, view} ->
            Logger.info("Stored a captured reflection (#{view["chars"]} chars, id=#{view["id"]})")

          {:error, reason} ->
            Logger.warning("Refused a captured reflection: #{Reflections.explain(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Could not decode a captured reflection: #{inspect(reason)}")
    end

    :ok
  end

  # The three verbs reached by `"companion.reflections." <> _`. Each of them
  # answers its caller — a subject we do not recognise gets a refusal rather
  # than a timeout, so a typo in a caller is visible instead of silent.
  defp handle_reflections_request(%{topic: "companion.reflections.capture"} = msg),
    do: handle_reflections_capture_request(msg)

  defp handle_reflections_request(%{topic: "companion.reflections.list"} = msg),
    do: handle_reflections_list_request(msg)

  defp handle_reflections_request(%{topic: "companion.reflections.read"} = msg),
    do: handle_reflections_read_request(msg)

  defp handle_reflections_request(msg) do
    Logger.warning("Unknown reflections subject: #{msg.topic}")

    reply(
      msg,
      Reply.error("there is no such reflections subject: #{msg.topic}", :validation_error)
    )
  end

  defp handle_reflections_capture_request(msg) do
    response =
      case store_reflection(decode_body(msg.body)) do
        {:ok, view} ->
          Reply.ok(%{"reflection" => view})

        {:error, reason} ->
          Reply.error(
            Reflections.explain(reason),
            refusal_code(reason)
          )
      end

    reply(msg, response)
  end

  defp handle_reflections_list_request(msg) do
    limit = decode_body(msg.body) |> Map.get("limit", Reflections.default_limit())

    response =
      case read_reflections(limit) do
        {:ok, reflections} ->
          Reply.ok(%{
            "reflections" => reflections,
            "count" => length(reflections)
          })

        {:error, reason} ->
          Reply.error(
            Reflections.explain(reason),
            refusal_code(reason)
          )
      end

    reply(msg, response)
  end

  defp handle_reflections_read_request(msg) do
    id = decode_body(msg.body) |> Map.get("id")

    response =
      case read_reflection(id) do
        {:ok, reflection} ->
          Reply.ok(%{"reflection" => reflection})

        {:error, reason} ->
          Reply.error(
            Reflections.explain(reason),
            refusal_code(reason)
          )
      end

    reply(msg, response)
  end

  # The store is a database. A failure there is not a refusal, it is a missing
  # answer — and a raised bug must stay a raised bug in the log rather than
  # become a plausible "the store is down". Both are caught here, at the
  # boundary where an answer has to exist, because a raise inside handle_info
  # would take the subscriber down with it and lose every reflection after it.
  defp store_reflection(payload) do
    Reflections.capture(payload)
  catch
    kind, reason ->
      Logger.error("Reflection store failed (#{kind}): #{inspect(reason)}")
      {:error, :store_failed}
  end

  defp read_reflections(limit) do
    Reflections.list(limit)
  catch
    kind, reason ->
      Logger.error("Reflection read failed (#{kind}): #{inspect(reason)}")
      {:error, :store_failed}
  end

  defp read_reflection(id) do
    Reflections.get(id)
  catch
    kind, reason ->
      Logger.error("Reflection read failed (#{kind}): #{inspect(reason)}")
      {:error, :store_failed}
  end

  # A store that could not be reached and a payload that was refused are
  # different answers, and a caller that cannot tell them apart will retry the
  # wrong one.
  defp refusal_code(:store_failed), do: :unavailable
  defp refusal_code(:not_found), do: :not_found
  defp refusal_code(_other), do: :validation_error

  defp decode_body(""), do: %{}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp reply(msg, response) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Gnat.pub(conn, msg.reply_to, response)

      {:error, reason} ->
        Logger.warning(
          "Failed to get NATS connection to reply to #{msg.topic}: #{inspect(reason)}"
        )
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    register_with_role(state)
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp handle_presence_update(msg) do
    # Companion.presence messages come from the witness system (eir-witness.sh)
    # They're not event-envelope-wrapped, just raw JSON
    case Jason.decode(msg.body) do
      {:ok, payload} ->
        Logger.info(
          "Eir presence update: #{Map.get(payload, "message", "silent")} (source: #{Map.get(payload, "source", "unknown")})"
        )

        # Could trigger downstream behavior here (notification, reflection trigger, etc.)
        # For now, just log it so we know it's arriving
        :ok

      {:error, reason} ->
        Logger.warning("Failed to decode companion.presence message: #{inspect(reason)}")
    end
  end

  defp handle_pubsub(msg) do
    case BotArmyLibraryCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message, msg.topic)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end
  end

  # Message routing
  defp route_message(message, topic) do
    event = message["event"]

    case event do
      "companion.heartbeat" ->
        BotArmyCompanion.Handlers.HeartbeatHandler.handle_heartbeat(message)

      _ ->
        Logger.debug("Unknown companion event type: #{event} from #{topic}")
    end
  end

  # Request/reply handlers
  # defp handle_task_list(msg, state) do
  #   response =
  #     case get_tasks() do
  #       {:ok, tasks} ->
  #         Reply.ok(%{"tasks" => tasks})
  #
  #       {:error, reason} ->
  #         Reply.error(inspect(reason), :list_failed)
  #     end
  #
  #   if state.conn do
  #     Gnat.pub(state.conn, msg.reply_to, response)
  #   end
  # end
end
