defmodule BotArmyCompanion.PulsePublisher do
  @moduledoc """
  Periodic health publisher for Companion Bot.

  Two channels, aligned with `docs/SYNAPSE_CONTEXT_HYDRATION_CONTRACT.md`:

  1. **`system.health`** — lightweight liveness envelope every 30s so Synapse
     fleet views (90s staleness) stay **online** when the bot is running.
  2. **`bot.companion.pulse`** — richer metrics every 30 minutes (lower NATS volume).

  Health signal rules (`health_signal/0` → pulse + heartbeat status):

  - `:nominal` — healthy
  - `:degraded` — minor issues or zero activity
  - `:critical` — errors or operational issues

  Customize `record_metric/2` and `health_signal/0` for domain-specific logic.
  """

  use GenServer
  require Logger

  # Under Synapse `system.health` stale window (90s); 30s cadence leaves margin for jitter.
  @health_interval_ms 30 * 1000
  @publish_interval_ms 30 * 60 * 1000
  # Autonomous reflection cadence: the reflection cycle gathers system state and
  # queries bridge.chat, so it's minutes of work — run it every 4 hours, first
  # pass 5 minutes after boot so the beam and NATS settle before reflecting.
  @reflection_warmup_ms 5 * 60 * 1000
  @reflection_interval_ms 4 * 60 * 60 * 1000
  @service_name "companion"
  @envelope_source "bot_army_companion"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Companion Bot pulse publisher")
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    send(self(), :publish_health)
    send(self(), :publish_pulse)
    Process.send_after(self(), :run_reflection, @reflection_warmup_ms)
    {:ok, %{started_at: started_at}}
  end

  @impl true
  def handle_info(:publish_health, state) do
    Task.start(fn -> publish_system_health(state) end)
    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_reflection, state) do
    Task.start(fn -> execute_reflection_task() end)
    Process.send_after(self(), :run_reflection, @reflection_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse() end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_metric, key, value}, state) do
    metrics = Map.get(state, :metrics, %{})
    updated_metrics = Map.put(metrics, key, value)
    {:noreply, Map.put(state, :metrics, updated_metrics)}
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp publish_pulse do
    signal = health_signal()
    metrics = collect_metrics()

    pulse = %{
      service: @service_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      health: signal,
      metrics: metrics
    }

    case BotArmyLibraryRuntime.NATS.Publisher.publish("bot.#{@service_name}.pulse", pulse) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published pulse: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
    end
  end

  defp publish_system_health(%{started_at: started_at}) do
    tenant_id =
      System.get_env("BOT_ARMY_TENANT_ID") || BotArmyLibraryRuntime.Tenant.default_tenant_id()

    signal = health_signal()

    uptime_seconds =
      DateTime.diff(DateTime.utc_now() |> DateTime.truncate(:second), started_at, :second)

    case BotArmyLibraryRuntime.SynapseHealth.publish(
           source_node: node() |> Atom.to_string(),
           triggered_by: @envelope_source,
           service: @service_name,
           tenant_id: tenant_id,
           health_signal: signal,
           uptime_seconds: max(uptime_seconds, 0)
         ) do
      {:ok, _} ->
        Logger.debug("[PulsePublisher] Published system.health: #{signal}")

      {:error, reason} ->
        Logger.warning("[PulsePublisher] Failed to publish system.health: #{inspect(reason)}")
    end
  end

  defp collect_metrics do
    active_thoughts = count_active_thoughts()
    %{active_thoughts: active_thoughts}
  end

  defp count_active_thoughts do
    try do
      BotArmyCompanion.Thoughts.list_active_thoughts() |> Enum.count()
    rescue
      _ -> 0
    end
  end

  defp health_signal do
    case count_active_thoughts() do
      0 -> :degraded
      _ -> :nominal
    end
  end

  # Execute reflection cycle and write observations to PARA
  # Runs every @reflection_interval_ms via :run_reflection; on-demand requests
  # still go through companion.reflection → Consumer → ReflectionHandler.
  defp execute_reflection_task do
    try do
      Logger.info("PulsePublisher: Executing scheduled reflection cycle")
      BotArmyCompanion.Handlers.ReflectionHandler.execute_reflection()
    rescue
      e ->
        Logger.warning("PulsePublisher: Reflection execution failed: #{inspect(e)}")
    end
  end
end
