defmodule BotArmyCompanion.NATS.Consumer do
  @moduledoc """
  NATS message consumer for companion.

  Subscribes to NATS subjects and routes messages to handlers.
  Uses standardized Reply format for request/reply patterns.

  All request/reply handlers should return responses using Reply helpers:
  - BotArmyLibraryRuntime.NATS.Reply.ok(data) for success
  - BotArmyLibraryRuntime.NATS.Reply.error(message, code) for errors
  """

  use GenServer
  require Logger

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
    }
  ]

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
      [
        "companion.heartbeat",
        "companion.reflection",
        "companion.observations.list",
        "companion.observations.read",
        "companion.observations.reply"
      ]
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

      process_message(msg)
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

      _ ->
        Logger.debug("Unknown request/reply subject: #{msg.topic}")
    end
  end

  defp handle_heartbeat_request(msg) do
    Logger.info("DEBUG: handle_heartbeat_request called, reply_to=#{msg.reply_to}")

    response =
      case BotArmyCompanion.Handlers.HeartbeatHandler.handle_heartbeat(msg.body) do
        {:reply, %{ok: true, data: data}} ->
          BotArmyLibraryRuntime.NATS.Reply.ok(data)

        {:reply, %{ok: false, data: data, error: reason}} ->
          # Handler includes both data (status/duration) and error message
          BotArmyLibraryRuntime.NATS.Reply.error(
            %{"data" => data, "error" => reason},
            :heartbeat_failed
          )

        {:reply, result} ->
          # Fallback for any other reply format
          Logger.warning("Unexpected heartbeat handler response format: #{inspect(result)}")
          BotArmyLibraryRuntime.NATS.Reply.error("Unexpected response format", :internal_error)
      end

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        # Response needs to be JSON-encoded before sending via Gnat.pub
        encoded_response = Jason.encode!(response)
        Gnat.pub(conn, msg.reply_to, encoded_response)

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
      BotArmyLibraryRuntime.NATS.Reply.ok(%{
        "job_id" => job_id,
        "status" => "accepted",
        "note" =>
          "Reflection running in background. Poll companion.reflection.status to check progress."
      })

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        encoded_response = Jason.encode!(response)
        Gnat.pub(conn, msg.reply_to, encoded_response)

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

    case BotArmyCompanion.Handlers.HeartbeatHandler.execute_reflection() do
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
          BotArmyLibraryRuntime.NATS.Reply.ok(%{"observations" => observations})

        {:error, reason} ->
          BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :list_failed)
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
              BotArmyLibraryRuntime.NATS.Reply.ok(%{"filename" => filename, "content" => content})

            {:error, reason} ->
              BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :read_failed)
          end

        _ ->
          BotArmyLibraryRuntime.NATS.Reply.error("Missing 'filename'", :bad_request)
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
          BotArmyLibraryRuntime.NATS.Reply.ok(%{"filename" => filename})

        {:error, reason} ->
          BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :reply_failed)
      end

    reply(msg, response)
  rescue
    e ->
      Logger.error("Error handling companion.observations.reply request: #{inspect(e)}")
  end

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
  #         BotArmyLibraryRuntime.NATS.Reply.ok(%{"tasks" => tasks})
  #
  #       {:error, reason} ->
  #         BotArmyLibraryRuntime.NATS.Reply.error(inspect(reason), :list_failed)
  #     end
  #
  #   if state.conn do
  #     Gnat.pub(state.conn, msg.reply_to, response)
  #   end
  # end
end
