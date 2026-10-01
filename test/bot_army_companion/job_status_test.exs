defmodule BotArmyCompanion.JobStatusTest do
  @moduledoc """
  The two bots' words for a job, read by one rule.

  The defect this file exists for was not a missing clause, it was a second
  vocabulary: the bridge marks a running job `processing`, the llm bot says
  `pending`, and the poller that only knew `pending` logged an error once a
  second for work that was being done. So each shape below is a real reply from a
  real producer, and the last test is the one that failed in production.
  """

  use ExUnit.Case, async: true

  alias BotArmyCompanion.JobStatus

  describe "the llm bot's replies" do
    test "a finished job carries its result" do
      assert {:done, %{"content" => "the words"}} =
               JobStatus.step(%{
                 "ok" => true,
                 "status" => "completed",
                 "result" => %{"content" => "the words"}
               })
    end

    test "a job that is still running waits" do
      assert :wait = JobStatus.step(%{"ok" => true, "status" => "pending"})
    end

    test "a job with no result yet still finished (the result is read next time)" do
      assert {:done, nil} = JobStatus.step(%{"ok" => true, "status" => "completed"})
    end

    test "a job that failed says so" do
      assert {:failed, "model exploded"} =
               JobStatus.step(%{
                 "ok" => true,
                 "status" => "failed",
                 "error" => "model exploded"
               })
    end

    test "a job the bot does not know is missing, not unreadable" do
      assert :missing = JobStatus.step(%{"ok" => false, "error" => "missing_job_id"})
    end
  end

  describe "the bridge's replies" do
    # `Deferred.update_job(job_id, :processing)` — the word this lane did not know.
    test "a job being processed is still running" do
      assert :wait = JobStatus.step(%{"ok" => true, "status" => "processing"})
    end

    test "the bridge also answers without an ok flag" do
      assert :wait = JobStatus.step(%{"status" => "pending"})
      assert :wait = JobStatus.step(%{"status" => "processing"})
    end

    test "a completed job carries its result whatever shape it is in" do
      assert {:done, %{"response" => "the words"}} =
               JobStatus.step(%{
                 "ok" => true,
                 "status" => "completed",
                 "result" => %{"response" => "the words"}
               })

      assert {:done, "the words"} =
               JobStatus.step(%{"ok" => true, "status" => "completed", "result" => "the words"})
    end
  end

  describe "a bot that answers" do
    test "a status word this module has never seen is still a job that exists" do
      # Being told something we do not recognise is not being told nothing: the
      # job is real, so waiting is the honest response. Only silence gives up.
      assert :wait = JobStatus.step(%{"ok" => true, "status" => "reticulating"})
    end

    test "an unreadable reply is unreadable" do
      assert :unreadable = JobStatus.step(%{"unexpected" => "shape"})
      assert :unreadable = JobStatus.step({:error, :timeout})
      assert :unreadable = JobStatus.step(nil)
      assert :unreadable = JobStatus.step("a bare string")
    end
  end
end
