defmodule BotArmyCompanion.JobStatus do
  @moduledoc """
  One owner of the question "is that job finished?", asked of two bots.

  The companion waits on backgrounded work in two places, and each one was
  written against a different producer:

    * the answer lane polls `llm.job.status`, served by the llm bot, whose store
      says `pending` while a job runs;
    * the legacy reflection path polls `bridge.job.status`, served by the bridge,
      whose `Deferred` marks a running job `processing`.

  Both reply in the same shape but not with the same words, and the second reader
  only knew the first bot's word. So a running job read as an error: the poller
  logged `Status check error` once a second for a job that was working, and the
  reflection failed after a minute. Measured on 2026-10-01 at 06:02
  (`Reflection task 424d998b… failed`).

  The vocabulary therefore lives here, once, and both readers ask this module what
  a reply means. Public and pure on purpose: the words *are* the rule, and a rule
  that cannot be asserted without a broker is a rule nobody can hold.
  """

  @type step :: {:done, term()} | {:failed, term()} | :wait | :missing | :unreadable

  # A job that is still going, in every word either producer has used for it.
  @waiting ~w(pending processing)

  @doc """
  What a status reply means.

    * `{:done, result}` — the job ended and this is its result;
    * `{:failed, reason}` — the job ended badly;
    * `:wait` — the job exists and has not ended;
    * `:missing` — the bot we asked does not know this job;
    * `:unreadable` — the reply is not a status reply at all.
  """
  @spec step(term()) :: step()
  def step(%{"ok" => true, "status" => "completed"} = reply),
    do: {:done, Map.get(reply, "result")}

  def step(%{"ok" => true, "status" => "failed"} = reply), do: {:failed, Map.get(reply, "error")}

  def step(%{"ok" => false}), do: :missing

  def step(%{"status" => status}) when status in @waiting, do: :wait

  # A word neither producer uses yet, from a bot that answered: it is telling us
  # the job exists, so we keep waiting rather than calling it unreachable. Being
  # told something we do not recognise is not the same as being told nothing.
  def step(%{"ok" => true, "status" => status}) when is_binary(status), do: :wait

  def step(_other), do: :unreadable
end
