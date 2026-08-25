defmodule BotArmyCompanion.Application do
  @moduledoc """
  Companion Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    # Configure Personality.Repo for heartbeat persistence
    Application.put_env(:bot_army_library_runtime, :personality_repo, BotArmyCompanion.Repo)

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyCompanion.Supervisor]

    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test do
      children
    else
      [{BotArmyCompanion.Repo, []} | children]
    end
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test do
      children
    else
      [{BotArmyCompanion.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_workers(children) do
    if @env == :test or skip_workers?() do
      children
    else
      [
        # Leader/standby election for dual-node (air + mini) deployment — must
        # start before the consumer so its first on_role_change call lands
        # while the consumer is still connecting (not yet subscribed either way).
        {BotArmyLibraryRuntime.LeaderElection,
         service: "companion",
         node_name: BotArmyLibraryRuntime.ConfigLoader.get("NODE_NAME", "unknown"),
         default_role: BotArmyLibraryRuntime.ConfigLoader.get_role("COMPANION_NODE_ROLE"),
         on_role_change: {BotArmyCompanion.NATS.Consumer, :leader_role_changed, []}},
        # NATS consumer for companion.heartbeat requests
        {BotArmyCompanion.NATS.Consumer, []}
        | children
      ]
    end
  end

  # Skip workers if running during database migrations (release.eval context)
  # Set during Salt deployment: `export BOT_SKIP_WORKERS=true` before running migrations
  defp skip_workers? do
    System.get_env("BOT_SKIP_WORKERS") == "true"
  end
end
