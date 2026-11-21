defmodule BotArmyCompanion.Letters.Worker do
  @moduledoc """
  The pen pal's clock: once a minute, writes the replies that have come due.

  Each tick does one `run_once/1`: put abandoned claims back (`Letters.reclaim_stale/1`), claim
  what is due (`Letters.claim_due/1`, atomic), and answer it together (`Letters.deliver/2`). Only
  one delivery runs at a time (a model can take minutes), so a slow reply is waited for, not
  overtaken by a second one.

  A node without the letters key never claims anything. The companion runs on two nodes and mini
  does not hold this channel's key; a node that claimed letters it could not seal a reply to
  would mark them failed, which is worse than leaving them for the node that can.

  Nothing here talks to Abby: the worker writes a letter into the thread and stops. It sends no
  notification, counts nothing, and does not mind if the letter is never opened.
  """

  use GenServer

  require Logger

  alias BotArmyCompanion.{Letters, Sealed}

  @default_tick_ms 60_000

  # -- one pass --------------------------------------------------------------------------

  @doc """
  One pass of the clock. Returns `:idle` (nothing due, or this node cannot write letters),
  `{:delivered, view}`, or `{:error, reason}` (the claimed letters are marked `failed`).
  """
  @spec run_once(keyword()) :: :idle | {:delivered, map()} | {:error, term()}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if ready?(), do: pass(now, opts), else: :idle
  end

  defp pass(now, opts) do
    Letters.reclaim_stale(now)

    case Letters.claim_due(now) do
      [] -> :idle
      ids -> ids |> Letters.deliver(Keyword.put(opts, :now, now)) |> delivered()
    end
  end

  defp delivered({:ok, view}), do: {:delivered, view}
  defp delivered({:error, _} = error), do: error

  @doc "Whether this node holds the letters key, and so may claim and answer letters."
  @spec ready?() :: boolean()
  def ready? do
    match?({:ok, _}, Sealed.seal(%{}, Sealed.letters_kid(), "ready"))
  end

  # -- the process -----------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      run: Keyword.get(opts, :run, &run_once/0),
      in_flight: nil
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{in_flight: nil} = state) do
    run = state.run

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        try do
          run.()
        rescue
          e -> {:error, {:crashed, e.__struct__}}
        end
      end)

    schedule(state)
    {:noreply, %{state | in_flight: task.ref}}
  end

  # A delivery is still running: this tick passes, and the next one looks again.
  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{in_flight: ref} = state) do
    Process.demonitor(ref, [:flush])
    log(result)
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: ref} = state) do
    Logger.error("[Letters.Worker] delivery task exited (#{inspect(reason_tag(reason))})")
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Only codes and counts: a result can carry a reply, and a reply is her letter.
  defp log(:idle), do: :ok
  defp log({:delivered, _view}), do: Logger.info("[Letters.Worker] a reply was written")

  defp log({:error, reason}),
    do:
      Logger.warning(
        "[Letters.Worker] a reply could not be written (#{inspect(reason_tag(reason))})"
      )

  defp log(_), do: :ok

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp reason_tag(_), do: :other

  defp schedule(%{tick_ms: :manual}), do: :ok
  defp schedule(%{tick_ms: ms}), do: Process.send_after(self(), :tick, ms)

  defp task_supervisor, do: BotArmyCompanion.TaskSupervisor
end
