defmodule BotArmyCompanion.Handlers.HeartbeatHandler do
  @moduledoc """
  Companion heartbeat handler - provides basic liveness checks.
  """

  require Logger

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
end
