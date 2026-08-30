defmodule BotArmyCompanion.Wins do
  @moduledoc """
  Gathers "recent wins" from various sources to provide positive context for reflections.
  """

  require Logger
  alias BotArmyCompanion.ParaClient

  @daily_log_path "projects/Bot Army/progress/DAILY_LOG.md"
  # Hypothesized PARA path
  @right_turns_path "projects/Bot Army/progress/right-turns.md"
  @gtd_task_list_subject "gtd.task.list"

  @doc """
  Fetches recent wins from PARA logs and completed GTD tasks.
  """
  def fetch_recent_wins do
    Logger.debug("[Wins] Fetching recent wins from all sources...")

    wins =
      [
        fetch_daily_log_wins(),
        fetch_right_turn_wins(),
        fetch_gtd_wins()
      ]
      |> List.flatten()
      |> Enum.uniq()

    Logger.debug("[Wins] Found #{length(wins)} recent wins")
    wins
  end

  defp fetch_daily_log_wins do
    Logger.debug("[Wins] Sourcing from Daily Log...")

    case ParaClient.read_file(@daily_log_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.filter(fn line -> String.starts_with?(line, "- tracker:") end)
        |> Enum.map(fn line -> String.trim_leading(line, "- ") end)

      _ ->
        Logger.warning("[Wins] Could not read Daily Log: #{@daily_log_path}")
        []
    end
  end

  defp fetch_right_turn_wins do
    Logger.debug("[Wins] Sourcing from Right Turns...")

    case ParaClient.read_file(@right_turns_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line -> String.trim(line) == "" end)

      _ ->
        Logger.warning("[Wins] Could not read Right Turns: #{@right_turns_path}")
        []
    end
  end

  defp fetch_gtd_wins do
    Logger.debug("[Wins] Sourcing from GTD completed tasks...")

    payload = %{
      "status" => "completed",
      "limit" => 50
    }

    case request_gtd_tasks(payload) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        seven_days_ago = DateTime.utc_now() |> DateTime.add(-7 * 24 * 60 * 60, :second)

        tasks
        |> Enum.filter(fn task ->
          case task["completed_at"] do
            nil ->
              false

            completed_iso when is_binary(completed_iso) ->
              case DateTime.from_iso8601(completed_iso) do
                {:ok, dt, _} -> DateTime.compare(dt, seven_days_ago) == :gt
                _ -> false
              end
          end
        end)
        |> Enum.map(fn task -> "Completed task: #{task["title"]}" end)

      {:ok, response} ->
        Logger.warning("[Wins] Unexpected GTD response: #{inspect(response)}")
        []

      {:error, reason} ->
        Logger.warning("[Wins] GTD request failed: #{inspect(reason)}")
        []
    end
  end

  defp request_gtd_tasks(payload) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        case Gnat.request(conn, @gtd_task_list_subject, Jason.encode!(payload), timeout: 5000) do
          {:ok, msg} -> {:ok, Jason.decode!(msg.body)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
