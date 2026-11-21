defmodule BotArmyCompanion.LettersMissionWriterTest do
  @moduledoc """
  The clock that tells Eir's missions: one pass at a time, a pass that crashes does not take it down,
  and the cutoff is when it started (never the beginning of history).
  """

  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyCompanion.Letters.MissionWriter

  setup do
    start_supervised!({Task.Supervisor, name: BotArmyCompanion.TaskSupervisor})
    :ok
  end

  defp start(opts) do
    id = {:writer, System.unique_integer([:positive])}

    start_supervised!(%{
      id: id,
      start: {MissionWriter, :start_link, [Keyword.merge([tick_ms: :manual, name: nil], opts)]}
    })
  end

  defp tick(pid) do
    send(pid, :tick)
    # a synchronous call after the tick: the writer has handled it by the time this returns
    :sys.get_state(pid)
  end

  test "a tick runs one pass, with a cutoff and the configured pace" do
    test = self()

    pid =
      start(
        since: "2026-11-21T07:00:00Z",
        max_per_pass: 1,
        run: fn opts ->
          send(test, {:ran, opts})
          {:ok, []}
        end
      )

    tick(pid)
    assert_receive {:ran, opts}, 1_000
    assert opts[:since] == "2026-11-21T07:00:00Z"
    assert opts[:max_per_pass] == 1
  end

  test "with no cutoff named, it is the moment the writer started, not the beginning of history" do
    test = self()
    before = DateTime.utc_now()

    pid =
      start(
        run: fn opts ->
          send(test, {:ran, opts})
          {:ok, []}
        end
      )

    tick(pid)
    assert_receive {:ran, opts}, 1_000

    {:ok, since, _} = DateTime.from_iso8601(opts[:since])
    assert DateTime.compare(since, DateTime.add(before, -2, :second)) in [:gt, :eq]
    assert DateTime.compare(since, DateTime.utc_now()) in [:lt, :eq]
  end

  test "a tick that arrives while a pass is still running does not start a second" do
    test = self()

    pid =
      start(
        since: "2026-11-21T07:00:00Z",
        run: fn _opts ->
          send(test, :started)

          receive do
            :finish -> {:ok, []}
          end
        end
      )

    tick(pid)
    assert_receive :started, 1_000
    tick(pid)
    refute_receive :started, 100

    %{in_flight: ref} = :sys.get_state(pid)
    assert is_reference(ref)
  end

  test "a pass that crashes is survived, and the next tick runs again" do
    test = self()

    pid =
      start(
        since: "2026-11-21T07:00:00Z",
        run: fn _opts ->
          send(test, :ran)
          raise "the model exploded"
        end
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        tick(pid)
        assert_receive :ran, 1_000
        Process.sleep(50)
        tick(pid)
        assert_receive :ran, 1_000
        Process.sleep(50)
      end)

    assert Process.alive?(pid)
    # caught in the pass and reported as one that could not run, by the exception's name only:
    # not the task dying under the writer, and never the exception's message
    assert log =~ "could not run ({:crashed, RuntimeError})" or log =~ "could not run (:crashed)"
    refute log =~ "the model exploded"
    refute log =~ "exited"
  end

  test "a pass that wrote a letter says so in the log, and an idle one says nothing" do
    pid = start(since: "x", run: fn _ -> {:ok, [{"m1", :written}]} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        tick(pid)
        Process.sleep(50)
      end)

    assert log =~ "[Letters.MissionWriter] wrote 1 mission letter"

    idle = start(since: "x", run: fn _ -> {:ok, []} end)

    quiet =
      ExUnit.CaptureLog.capture_log(fn ->
        tick(idle)
        Process.sleep(50)
      end)

    refute quiet =~ "MissionWriter"
  end

  test "a pass that could not begin is logged by its reason, never its contents" do
    pid = start(since: "x", run: fn _ -> {:error, :no_soul} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        tick(pid)
        Process.sleep(50)
      end)

    assert log =~ "could not run (:no_soul)"
  end

  test "a failed mission is logged as a count and a reason, not its text" do
    pid =
      start(
        since: "x",
        run: fn _ -> {:ok, [{"m1", {:failed, :unavailable}}, {"m2", :written}]} end
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        tick(pid)
        Process.sleep(50)
      end)

    assert log =~ "wrote 1 mission letter"
    assert log =~ "1 failed (unavailable)"
  end

  describe "a letter the model cannot get right" do
    # Each tick, the pass is told which missions to leave alone; a mission that comes back as not good
    # enough is counted, and past the limit it is left alone (until the next start) so a hopeless
    # letter does not cost a model call every ten minutes forever.
    defp passes(pid, results_per_pass, test) do
      Enum.map(results_per_pass, fn _ ->
        tick(pid)
        assert_receive {:ran, opts}, 1_000
        Process.sleep(30)
        opts
      end)
      |> tap(fn _ -> send(test, :done) end)
    end

    test "is skipped after it has failed to be good enough the allowed number of times" do
      test = self()
      Process.put(:n, 0)
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      pid =
        start(
          since: "x",
          max_tries: 2,
          run: fn opts ->
            send(test, {:ran, opts})
            Agent.update(agent, &(&1 + 1))
            {:ok, [{"m1", {:failed, :not_good_enough}}]}
          end
        )

      [first, second, third] = passes(pid, [1, 2, 3], test)

      assert first[:skip] == []
      assert second[:skip] == []
      assert third[:skip] == ["m1"]
    end

    test "a failure that is the model's, not the letter's, is never counted against it" do
      test = self()

      pid =
        start(
          since: "x",
          max_tries: 1,
          run: fn opts ->
            send(test, {:ran, opts})
            {:ok, [{"m1", {:failed, :unavailable}}, {"m2", {:failed, :ungradable}}]}
          end
        )

      [_, second, third] = passes(pid, [1, 2, 3], test)
      assert second[:skip] == []
      assert third[:skip] == []
    end

    test "a letter that is written is never counted, and one failure among others does not skip the rest" do
      test = self()

      pid =
        start(
          since: "x",
          max_tries: 1,
          run: fn opts ->
            send(test, {:ran, opts})
            {:ok, [{"m1", :written}, {"m2", {:failed, :not_good_enough}}]}
          end
        )

      [_, second] = passes(pid, [1, 2], test)
      assert second[:skip] == ["m2"]
    end
  end

  describe "the application's child list" do
    test "starts the writer unless it is turned off" do
      Application.delete_env(:bot_army_companion, :letters)

      assert [{BotArmyCompanion.Letters.MissionWriter, []}] =
               BotArmyCompanion.Application.mission_writer()

      Application.put_env(:bot_army_companion, :letters, mission: [enabled: false])
      on_exit(fn -> Application.delete_env(:bot_army_companion, :letters) end)
      assert [] = BotArmyCompanion.Application.mission_writer()
    end
  end

  describe "settings/0" do
    test "are on by default, ten minutes apart, two at a time, three tries a letter" do
      Application.delete_env(:bot_army_companion, :letters)

      assert %{enabled: true, interval_ms: 600_000, max_per_pass: 2, max_tries: 3, since: nil} =
               MissionWriter.settings()
    end

    test "are read from the letters config, and can be turned off" do
      Application.put_env(:bot_army_companion, :letters,
        mission: [
          enabled: false,
          interval_ms: 5_000,
          max_per_pass: 1,
          since: "2026-11-21T00:00:00Z"
        ]
      )

      on_exit(fn -> Application.delete_env(:bot_army_companion, :letters) end)

      assert %{enabled: false, interval_ms: 5_000, max_per_pass: 1, since: "2026-11-21T00:00:00Z"} =
               MissionWriter.settings()
    end

    test "a setting that is not usable falls back, rather than stopping the clock" do
      Application.put_env(:bot_army_companion, :letters,
        mission: [interval_ms: -3, max_per_pass: "many"]
      )

      on_exit(fn -> Application.delete_env(:bot_army_companion, :letters) end)

      assert %{interval_ms: 600_000, max_per_pass: 2} = MissionWriter.settings()
    end
  end
end
