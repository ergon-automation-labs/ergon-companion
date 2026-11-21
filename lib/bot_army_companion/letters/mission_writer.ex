defmodule BotArmyCompanion.Letters.MissionWriter do
  @moduledoc """
  The clock that tells Eir's missions (`BotArmyCompanion.Letters.Mission`).

  Every `interval_ms` it runs one pass in a supervised task, so a crash in a model call cannot take the
  clock with it, and never two passes at once. A pass looks for finished missions after a cutoff that
  have no letter yet and writes at most `max_per_pass` of them.

  ## The cutoff

  Defaults to the moment the writer started, so the missions that finished before it existed are never
  told by accident. The cost of that default is that a mission which finishes while the companion is
  down, or between a restart and its next pass, is not told; `since` in the letters config names an
  earlier cutoff to catch up on purpose.

  ## Settings

  `config :bot_army_companion, :letters, mission: [enabled: true, interval_ms: 600_000,
  max_per_pass: 2, max_tries: 3, since: nil]`. A setting that is not usable falls back to its default rather than
  stopping the clock.
  """

  use GenServer

  require Logger

  alias BotArmyCompanion.Letters.Mission

  @default_interval_ms 600_000
  @default_max_per_pass 2
  @default_max_tries 3
  # The first pass waits a little, so the leader election has settled before anything asks who leads.
  @first_pass_ms 120_000

  @doc "The settings, with defaults for anything unset or unusable."
  @spec settings() :: %{
          enabled: boolean(),
          interval_ms: pos_integer(),
          max_per_pass: pos_integer(),
          max_tries: pos_integer(),
          since: String.t() | nil
        }
  def settings do
    cfg = :bot_army_companion |> Application.get_env(:letters, []) |> Keyword.get(:mission, [])

    %{
      enabled: Keyword.get(cfg, :enabled, true) != false,
      interval_ms: positive(Keyword.get(cfg, :interval_ms), @default_interval_ms),
      max_per_pass: positive(Keyword.get(cfg, :max_per_pass), @default_max_per_pass),
      max_tries: positive(Keyword.get(cfg, :max_tries), @default_max_tries),
      since: text(Keyword.get(cfg, :since))
    }
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  def start_link(opts \\ []) do
    name =
      case Keyword.fetch(opts, :name) do
        {:ok, nil} -> []
        {:ok, name} -> [name: name]
        :error -> [name: __MODULE__]
      end

    GenServer.start_link(__MODULE__, opts, name)
  end

  @impl true
  def init(opts) do
    settings = settings()

    state = %{
      tick_ms: Keyword.get(opts, :tick_ms, settings.interval_ms),
      first_ms: Keyword.get(opts, :first_ms, @first_pass_ms),
      since:
        Keyword.get(opts, :since) || settings.since ||
          DateTime.utc_now() |> DateTime.to_iso8601(),
      max_per_pass: Keyword.get(opts, :max_per_pass, settings.max_per_pass),
      max_tries: Keyword.get(opts, :max_tries, settings.max_tries),
      tries: %{},
      run: Keyword.get(opts, :run, &Mission.write_new/1),
      in_flight: nil
    }

    schedule_first(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{in_flight: nil} = state) do
    run = state.run
    opts = [since: state.since, max_per_pass: state.max_per_pass, skip: given_up(state)]

    task =
      Task.Supervisor.async_nolink(BotArmyCompanion.TaskSupervisor, fn ->
        try do
          run.(opts)
        rescue
          e -> {:error, {:crashed, e.__struct__}}
        end
      end)

    schedule(state)
    {:noreply, %{state | in_flight: task.ref}}
  end

  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{in_flight: ref} = state) do
    Process.demonitor(ref, [:flush])
    log(result)
    {:noreply, %{state | in_flight: nil, tries: count_tries(state.tries, result)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: ref} = state) do
    Logger.error("[Letters.MissionWriter] a pass exited (#{inspect(reason_tag(reason))})")
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A letter the model could not get right, after its rewrites, is tried again on a later pass (the
  # model may do better), but only `max_tries` times: past that it is left alone until the next start,
  # so a hopeless letter does not cost a model call every pass forever. Only that failure counts. A
  # model that was down, or an editor that could not be read, says nothing about the letter.
  defp count_tries(tries, {:ok, results}) when is_list(results) do
    Enum.reduce(results, tries, fn
      {id, {:failed, :not_good_enough}}, acc -> Map.update(acc, id, 1, &(&1 + 1))
      _other, acc -> acc
    end)
  end

  defp count_tries(tries, _result), do: tries

  defp given_up(%{tries: tries, max_tries: max}),
    do: for({id, n} <- tries, n >= max, do: id)

  # Counts and reason names only: a letter's words, and a mission's, never reach a log.
  defp log({:ok, []}), do: :ok

  defp log({:ok, results}) when is_list(results) do
    written = Enum.count(results, &(elem(&1, 1) == :written))
    failed = for {_id, {:failed, reason}} <- results, do: reason_tag(reason)

    if written > 0 or failed != [] do
      Logger.info(
        "[Letters.MissionWriter] wrote #{written} mission letter(s)" <>
          if(failed == [],
            do: "",
            else: ", #{length(failed)} failed (#{Enum.join(Enum.uniq(failed), ", ")})"
          )
      )
    end
  end

  defp log({:error, reason}),
    do:
      Logger.warning(
        "[Letters.MissionWriter] a pass could not run (#{inspect(reason_tag(reason))})"
      )

  defp log(_), do: :ok

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp reason_tag(_), do: :other

  defp schedule_first(%{tick_ms: :manual}), do: :ok
  defp schedule_first(%{first_ms: ms}), do: Process.send_after(self(), :tick, ms)

  defp schedule(%{tick_ms: :manual}), do: :ok
  defp schedule(%{tick_ms: ms}), do: Process.send_after(self(), :tick, ms)
end
