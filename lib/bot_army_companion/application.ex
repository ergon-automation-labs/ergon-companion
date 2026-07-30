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
    # Note: BotArmyRuntime.Telemetry and BotArmyRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyCompanion.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        seed_thoughts()
        {:ok, pid}

      error ->
        error
    end
  end

  defp seed_thoughts do
    if @env != :test do
      BotArmyCompanion.Thoughts.seed_default_thoughts()
    end
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
    if @env == :test do
      children
    else
      # NATS consumer for companion.heartbeat requests
      [{BotArmyCompanion.NATS.Consumer, []} | children]
    end
  end
end
