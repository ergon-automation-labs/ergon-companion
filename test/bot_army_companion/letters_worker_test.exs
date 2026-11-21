defmodule BotArmyCompanion.LettersWorkerTest do
  use ExUnit.Case, async: false
  @moduletag :workers

  alias BotArmyCompanion.Letters.Worker

  # The process half of the clock needs no database: `:run` stands in for one pass.
  describe "the process" do
    setup do
      start_supervised!({Task.Supervisor, name: BotArmyCompanion.TaskSupervisor})
      :ok
    end

    defp start_worker(run) do
      start_supervised!({Worker, name: nil, tick_ms: :manual, run: run})
    end

    defp tick(pid), do: send(pid, :tick)

    test "a tick runs one pass in a task, off the worker's own process" do
      test = self()

      pid =
        start_worker(fn ->
          send(test, {:ran_in, self()})
          :idle
        end)

      tick(pid)
      assert_receive {:ran_in, task_pid}, 1_000
      refute task_pid == pid
    end

    test "a slow delivery is waited for, not overtaken: ticks while it runs start nothing" do
      test = self()

      pid =
        start_worker(fn ->
          send(test, :started)
          receive do: (:go -> :idle)
        end)

      tick(pid)
      assert_receive :started, 1_000
      tick(pid)
      tick(pid)
      refute_receive :started, 200

      %{in_flight: ref} = :sys.get_state(pid)
      assert is_reference(ref)
    end

    test "once the delivery ends, the next tick runs again" do
      test = self()
      counter = :counters.new(1, [])

      pid =
        start_worker(fn ->
          :counters.add(counter, 1, 1)
          send(test, {:pass, :counters.get(counter, 1)})
          :idle
        end)

      tick(pid)
      assert_receive {:pass, 1}, 1_000
      wait_idle(pid)
      tick(pid)
      assert_receive {:pass, 2}, 1_000
    end

    test "a pass that crashes is contained: the worker lives, and its message is never logged" do
      pid = start_worker(fn -> raise "provider choked on: my sister and I haven't spoken" end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          tick(pid)
          wait_idle(pid)
        end)

      assert Process.alive?(pid)
      refute log =~ "sister"
      refute log =~ "provider choked"
    end

    test "a result is logged as a code only, never as the reply" do
      pid = start_worker(fn -> {:delivered, %{"text" => "Dear Abby, about your sister. Eir"}} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          tick(pid)
          wait_idle(pid)
        end)

      refute log =~ "sister"
      assert log =~ "a reply was written"
    end

    defp wait_idle(pid, tries \\ 50) do
      case :sys.get_state(pid) do
        %{in_flight: nil} ->
          :ok

        _ when tries > 0 ->
          Process.sleep(20)
          wait_idle(pid, tries - 1)

        _ ->
          flunk("the delivery never finished")
      end
    end
  end

  describe "ready?/0: a node without the letters key never claims" do
    test "no key means not ready, so run_once is :idle and touches nothing" do
      System.delete_env("LETTERS_SEALED_KEYS")
      refute Worker.ready?()
      assert :idle = Worker.run_once()
    end

    test "with the key it is ready" do
      System.put_env(
        "LETTERS_SEALED_KEYS",
        Jason.encode!(%{"letters1" => Base.encode64(:binary.copy(<<4>>, 32))})
      )

      on_exit(fn -> System.delete_env("LETTERS_SEALED_KEYS") end)
      assert Worker.ready?()
    end

    test "only the LLM key is not enough: the letters channel is its own" do
      System.delete_env("LETTERS_SEALED_KEYS")

      System.put_env(
        "LLM_SEALED_KEYS",
        Jason.encode!(%{"k1" => Base.encode64(:binary.copy(<<4>>, 32))})
      )

      on_exit(fn -> System.delete_env("LLM_SEALED_KEYS") end)
      refute Worker.ready?()
    end
  end
end
