defmodule BotArmyCompanion.ReflectionAnswerLlmTest do
  @moduledoc """
  Waiting for a slow local model: the bell ends the wait, the status is read.

  An uncensored 27B takes minutes for a one-word answer, so the answer side waits
  as long as the job can live. Waiting well is the whole subject of this file:

  * the llm bot's bell ends the wait, so patience costs nothing while the model
    works (with a `:poll_ms` of a minute, a missing bell is an hour of hang);
  * a bell is a wake-up and not a proof — the job's status is still read, so a
    bell that races ahead of the result cannot be mistaken for the result;
  * a bell for someone else's job also ends the wait, and a bell that never comes
    leaves the old polling cadence untouched, so an older llm bot still works.
  """

  use ExUnit.Case, async: false

  alias BotArmyCompanion.JobBell
  alias BotArmyCompanion.ReflectionAnswer.Llm.Nats, as: LlmNats

  @job "5f1c9a34-0d6e-4c1e-8f2a-77c1d3a9c4b1"

  # A bus with three faces: it accepts the job, it answers status reads from a
  # script, and — where the script says so — it does what the llm bot does when a
  # job ends: ring the bell. The bell is sent to `self()` deliberately. This
  # process *is* the waiter (`answer/3` runs where it is called), so a message in
  # its own mailbox is exactly what the real bell delivers.
  defmodule ScriptedPublisher do
    @moduledoc false

    # The same job id as the test's `@job`: a nested module cannot see it.
    @job "5f1c9a34-0d6e-4c1e-8f2a-77c1d3a9c4b1"

    def request("llm.request.chat", _payload, _opts), do: {:ok, %{"job_id" => @job}}

    def request("llm.job.status", payload, _opts), do: status(payload["job_id"])

    defp status(job_id) do
      case Process.get(:status_script, []) do
        [step | rest] ->
          Process.put(:status_script, rest)
          reply(step, job_id)

        [] ->
          # Out of script: the job never finishes, which is what a real llm bot
          # says about a job that is still running.
          {:ok, %{"ok" => true, "status" => "pending"}}
      end
    end

    defp reply(:pending, _job_id), do: {:ok, %{"ok" => true, "status" => "pending"}}

    defp reply(:bell, job_id) do
      send(self(), {:job_bell, job_id})
      {:ok, %{"ok" => true, "status" => "pending"}}
    end

    defp reply(:other_bell, _job_id) do
      send(self(), {:job_bell, "someone-elses-job"})
      {:ok, %{"ok" => true, "status" => "pending"}}
    end

    defp reply(:completed, _job_id) do
      {:ok,
       %{
         "ok" => true,
         "status" => "completed",
         "result" => %{"content" => "the words", "model_used" => "qwen3.5-uncensored"}
       }}
    end

    defp reply(:failed, _job_id), do: {:ok, %{"ok" => true, "status" => "failed"}}
    defp reply(:missing, _job_id), do: {:ok, %{"ok" => false}}
    defp reply(:unreachable, _job_id), do: {:error, :timeout}
  end

  setup do
    original = Application.get_env(:bot_army_companion, :nats_publisher)

    on_exit(fn ->
      if original do
        Application.put_env(:bot_army_companion, :nats_publisher, original)
      else
        Application.delete_env(:bot_army_companion, :nats_publisher)
      end
    end)

    Application.put_env(:bot_army_companion, :nats_publisher, __MODULE__.ScriptedPublisher)
    Process.put(:status_script, [])

    :ok
  end

  test "the bell ends the wait, not the patience" do
    script([:bell, :completed])

    assert {:ok, %{text: "the words", model: "qwen3.5-uncensored"}} = answer(poll_ms: 60_000)
  end

  test "a bell for another job also ends the wait" do
    script([:other_bell, :completed])

    assert {:ok, %{text: "the words"}} = answer(poll_ms: 60_000)
  end

  test "a bell is a wake-up, not the result" do
    # The bell rings while the store still says pending, and the waiter goes back
    # to waiting. A waiter that believed the bell would produce an answer here;
    # there is no answer to produce, so the job's own budget runs out.
    script([:bell, :pending])

    assert {:error, :timeout} = answer(poll_ms: 10, budget_ms: 60)
  end

  test "with no bell at all the waiter asks on its own cadence" do
    # An llm bot older than the bell: the patience is also the polling cadence.
    script([:pending, :pending, :completed])

    assert {:ok, %{text: "the words"}} = answer(poll_ms: 5)
  end

  test "a job that failed is a model failure, not an empty answer" do
    script([:failed])

    assert {:error, :model_failed} = answer(poll_ms: 5)
  end

  test "a job that is gone is unavailable, not a model failure" do
    script([:missing])

    assert {:error, :unavailable} = answer(poll_ms: 5)
  end

  test "status reads that fail in a row give up rather than wait forever" do
    # One failed read is "the bus hiccupped"; three in a row is "nobody is
    # answering", and it is not worth spending an hour of the budget to find out.
    script([:unreachable, :unreachable, :unreachable, :completed])

    assert {:error, :unavailable} = answer(poll_ms: 5)
  end

  test "the patience running out is a timeout" do
    script([:pending])

    assert {:error, :timeout} = answer(poll_ms: 10, budget_ms: 30)
  end

  test "a waiter stops waiting when it is done" do
    script([:completed])

    assert {:ok, _answer} = answer(poll_ms: 5)

    # Registered for the length of the wait and no longer: a waiter left behind
    # would be woken for a job whose answer has already been recorded.
    assert :ok = JobBell.ring(@job)
    refute_received {:job_bell, _job_id}
  end

  defp script(steps), do: Process.put(:status_script, steps)

  defp answer(overrides) do
    LlmNats.answer("the system prompt", "her reflection", opts(overrides))
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        subject: "llm.request.chat",
        status_subject: "llm.job.status",
        model_type: "chat",
        lane: "uncensored",
        max_tokens: 900,
        # The job's own life, as the answer lane configures it: a test that needs
        # the bell to be the thing that ends the wait must not be ended by this.
        budget_ms: 3_600_000,
        poll_ms: 5,
        submit_timeout_ms: 20_000,
        status_timeout_ms: 10_000
      ],
      overrides
    )
  end
end
