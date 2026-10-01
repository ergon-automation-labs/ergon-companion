defmodule BotArmyCompanion.JobBellTest do
  @moduledoc """
  The local half of the llm bot's bell: waiters register, the consumer rings.

  The bell exists so a caller waiting an hour for a slow local model does not
  spend that hour asking. Two things must hold for it to be worth anything:
  a ringing bell must reach the waiter, and a bell for someone else's job must
  reach exactly one of them.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BotArmyCompanion.JobBell
  alias BotArmyCompanion.NATS.Consumer

  @job "6c0b7a12-3a7e-4f0e-9c2f-2db7b2a1b9f0"
  @other "11111111-1111-1111-1111-111111111111"

  test "a waiter is woken by the job it is waiting for" do
    :ok = JobBell.watch(@job)

    assert :ok = JobBell.ring(@job)
    assert_receive {:job_bell, @job}, 1_000
  end

  test "a bell for another job is not delivered to this waiter" do
    :ok = JobBell.watch(@job)

    assert :ok = JobBell.ring(@other)
    refute_receive {:job_bell, _job_id}, 300
  end

  test "ringing with nobody waiting is not an error" do
    assert :ok = JobBell.ring("22222222-2222-2222-2222-222222222222")
  end

  test "unwatching twice is not an error" do
    :ok = JobBell.watch(@job)
    assert :ok = JobBell.unwatch(@job)
    assert :ok = JobBell.unwatch(@job)
  end

  describe "the bell on the wire" do
    test "an llm-completion event wakes the waiter for that job" do
      :ok = JobBell.watch(@job)

      assert {:noreply, _state} = deliver(bell(%{"job_id" => @job, "status" => "completed"}))
      assert_receive {:job_bell, @job}, 1_000
    end

    test "a bell with no job id wakes nobody, and says so" do
      :ok = JobBell.watch(@job)

      log =
        capture_log(fn ->
          assert {:noreply, _state} = deliver(bell(%{"status" => "completed"}))
        end)

      refute_receive {:job_bell, _job_id}, 300
      assert log =~ "without a job id"
    end
  end

  # The envelope the llm bot actually publishes: the eight fields the shared
  # decoder requires, a status, and no words.
  defp bell(payload) do
    Jason.encode!(%{
      "event" => "llm.job.completed",
      "event_id" => "0f6b2c6a-9a2f-4b0f-9c1a-4c2d3e4f5a6b",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => "llm_proxy@air",
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "payload" => payload
    })
  end

  # Straight in through the door every other inbound message uses, so what the
  # test covers is the routing the fleet runs and not a shortcut beside it.
  defp deliver(body) do
    Consumer.handle_info(
      {:msg, %{topic: "events.llm.job.completed", body: body, reply_to: nil}},
      %{}
    )
  end
end
