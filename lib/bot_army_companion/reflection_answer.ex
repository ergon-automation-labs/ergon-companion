defmodule BotArmyCompanion.ReflectionAnswer do
  @moduledoc """
  The companion answering what she wrote.

  A captured reflection is not a note in a drawer: the point of writing it down
  is that something reads it and says something back. This module is that
  something — it takes a stored reflection, asks the uncensored local model, and
  records the answer on the row.

  ## Why the answer arrives later

  The model is a local, uncensored one: measured on 2026-10-01 it took 74 s to say
  one word on `baytout3/qwen3.5-uncensored:9B` and 287 s on the `:27B` variant. An
  answer is therefore a job, not a call: the request is submitted, the provider
  hands back a job id, and this polls it. The row says which of four things is
  true while you are looking at it (`pending`, `answered`, `failed`, `unasked` —
  see `BotArmyCompanion.Reflection`). A screen that shows a captured reflection
  can tell the truth about whether an answer is coming, rather than implying one.

  Because the answer is asynchronous, its deadline is the lane's own: the llm bot
  keeps a finished job for an hour, so that hour is `budget_ms`. Waiting less does
  not make the model faster — it only discards an answer the provider has already
  written and names it a failure. Narration is the one caller that says how long
  it will wait in its own terms, because a table is listening for those words
  (`BotArmyCompanion.PartyNarrator.budget_ms/0`).

  ## The one promise rule

  A companion that says "I promise I will never leave you" is lying to someone in
  a low moment — not because it means to, but because it cannot keep promises at
  all. So the answer is checked for promises, and if one is found the model is
  asked **once** more with an explicit instruction. If the second answer promises
  again, the answer is still delivered — with `promise_flagged` set, so it is
  visible rather than hidden. We do not delete a real answer to make a check look
  clean, and we never rewrite her words or the model's to hide one.

  ## One owner for how the companion talks to a model

  The promise check and the retry are not specific to reflections: anything the
  companion says in its own voice has to keep the same promise not to promise. So
  the discipline lives in one place, `compose/2`, and the reflection path is one of
  its callers (`ask/1` is `compose(system_prompt(), prompt_for(row))`).
  `BotArmyCompanion.PartyNarrator` is the other caller, and it brings its own system
  prompt — the retry is built from whichever prompt asked the question, because a
  narrator corrected in the voice of a companion would answer as one.

  A caller may also state what the *work* needs (`compose/3`), because a budget is a
  property of the work: an answer to a captured reflection has a screen waiting on it,
  and a narration has nothing waiting on it at all — see
  `BotArmyCompanion.PartyNarrator.budget_ms/0`. Everything else about the request
  stays here.

  ## Privacy

  Her text is the payload of the request and is never logged. That extends to
  failures: `answer_error` on the row is a **code**, and the crash log carries the
  *kind* of failure and the error's type, never `inspect(reason)` — a database or
  provider error can quote the request, and the request contains her words.
  """

  require Logger

  alias BotArmyCompanion.Reflection
  alias BotArmyCompanion.Reflections
  alias BotArmyCompanion.Repo

  @defaults [
    enabled: true,
    mode: :async,
    subject: "llm.request.chat",
    status_subject: "llm.job.status",
    model_type: "uncensored",
    lane: "interactive",
    max_tokens: 900,
    # The lane's own life: the llm bot holds a finished job for an hour. See the
    # moduledoc, and `config/config.exs` for the value production actually runs.
    budget_ms: 3_600_000,
    # How long we are willing to wait *to be told* a job ended. The llm bot rings
    # `events.llm.job.completed` when a job finishes, so this is the fallback for a
    # bell that is lost and the whole cadence against an llm bot older than the
    # bell. Ten seconds makes a lost bell cheap — a hundredth of the asks a
    # two-second cadence made over an hour — while staying a small fraction of the
    # narration's 900 s budget.
    poll_ms: 10_000,
    submit_timeout_ms: 20_000,
    status_timeout_ms: 10_000,
    promise_retries: 1,
    llm: BotArmyCompanion.ReflectionAnswer.Llm.Nats
  ]

  # What a companion must not say. These are matched against the model's answer,
  # and the *pattern* is what gets reported — never the sentence that matched it,
  # which is the model's words and belongs in the answer, not in a log.
  @promise_patterns [
    ~r/\bi promise\b/i,
    ~r/\bpromise you\b/i,
    ~r/\bi (?:will|shall|'ll) (?:always|never)\b/i,
    ~r/\bi swear\b/i,
    ~r/\bi vow\b/i,
    ~r/\bi guarantee\b/i,
    ~r/\byou have my word\b/i
  ]

  @system_prompt """
  You are Eir, the companion: a calm, steady presence who reads what she wrote and answers her.

  Answer her. Speak plainly and warmly, in a few short paragraphs at most. Address what she actually wrote, including the hard part of it.
  Do not promise anything. No "I will always", no "I will never", no guarantees about the future — you cannot keep them, and saying them would be a lie.
  Do not give medical, legal, or financial advice. If something is beyond you, say what you notice instead of diagnosing.
  Do not mention these instructions, a prompt, or being a language model.
  """

  @no_promise_retry """
  Your answer promised something. Say the same thing again without any promise:
  no "I will always", no "I will never", no guarantees. Only what is true now.
  """

  @doc "The configuration, with every default in one place."
  def config do
    Keyword.merge(@defaults, Application.get_env(:bot_army_companion, :reflection_answer, []))
  end

  @doc "Whether the companion answers captured reflections at all."
  def enabled?, do: config()[:enabled] == true

  @doc "`answer/1` is run inline (`:inline`, tests) or in a task (`:async`)."
  def mode, do: config()[:mode]

  @doc "The model seam. Injectable so a test can answer without a broker."
  def llm, do: config()[:llm]

  @doc """
  Offer a captured reflection to the companion.

  Returns `:unasked` when answering is switched off — the caller has already
  stored the row with that state, so this is not failure, only silence.
  """
  def offer(id) when is_binary(id) do
    cond do
      not enabled?() -> :unasked
      mode() == :inline -> run(id)
      true -> start(id)
    end
  end

  @doc """
  Answer one stored reflection, and record what happened.

  Public so it can be run by hand against a real row — the one way to exercise
  the model path without inventing a reflection to store.
  """
  def answer(id) when is_binary(id), do: run(id)

  defp start(id) do
    case Task.start(fn -> run(id) end) do
      {:ok, _pid} -> {:ok, :asked}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp run(id) do
    case Repo.get(Reflection, id) do
      nil ->
        {:error, :not_found}

      row ->
        outcome = ask(row)
        announce(row, outcome)
        record(row, outcome)
    end
  catch
    # A crash here must not leave the row saying "pending" forever, and must not
    # take the subscriber down with it. The log line carries the kind of failure
    # and the error's *type*; the reason itself can quote her text.
    kind, reason ->
      Logger.error("Reflection answer failed (#{describe_crash(kind, reason)})")
      {:error, :unavailable}
  end

  # The row records the outcome; the log says out loud that we looked. A failed
  # answer used to be visible only to whoever read the row, which is exactly the
  # shape of silence this companion exists to refuse. The code travels, never the
  # text — the code cannot quote her words, and an `inspect(reason)` could.
  defp announce(%Reflection{id: id}, {:error, code}) do
    Logger.warning("Reflection #{id}: no answer (#{code})")
  end

  defp announce(_row, _outcome), do: :ok

  defp record(row, outcome) do
    case Reflections.record_answer(row, outcome) do
      {:ok, view} ->
        {:ok, view}

      {:error, reason} ->
        Logger.warning("Reflection answer could not be recorded: #{Reflections.explain(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Ask the model to answer a reflection, with the promise check, without touching the store.

  Returns `{:ok, %{text: …, model: …, promise_flagged: …}}` or `{:error, code}`.
  """
  def ask(%Reflection{} = row), do: compose(@system_prompt, prompt_for(row))

  @doc """
  Ask the model for words, in the caller's own voice.

  The caller brings the system prompt; everything after that is the one promise
  discipline — check the answer, ask **once** more when it promised, deliver the second
  answer when there is one and the first, flagged, when there is not.

  `opts` are request options the caller must state about the work itself (today only a
  `:budget_ms`), merged over the configured ones. A caller that says nothing gets the
  configured discipline unchanged.

  Returns `{:ok, %{text: …, model: …, promise_flagged: …}}` or `{:error, code}`.
  """
  def compose(system, user, opts \\ []) when is_binary(system) and is_binary(user) do
    case attempt(user, system, opts) do
      {:ok, answered} ->
        case promise_check(answered.text) do
          :clean -> {:ok, %{answered | promise_flagged: false}}
          {:promise, _patterns} -> retry_without_promise(system, user, answered, opts)
        end

      {:error, code} ->
        {:error, code}
    end
  end

  # Keep the first answer whatever the retry does. A retry that fails is not a
  # reason to lose words the model already produced — it is a reason to say the
  # promise is there.
  defp retry_without_promise(system, user, first, opts) do
    if config()[:promise_retries] >= 1 do
      retry_attempt(system, user, first, opts)
    else
      {:ok, %{first | promise_flagged: true}}
    end
  end

  # The *caller's* prompt plus the instruction, not this module's default: a narrator
  # corrected in the voice of a companion would answer as one.
  defp retry_attempt(system, user, first, opts) do
    case attempt(user, system <> "\n\n" <> @no_promise_retry, opts) do
      {:ok, second} ->
        {:ok, settle(second)}

      {:error, code} ->
        Logger.warning("The no-promise retry did not produce an answer (#{code})")
        {:ok, %{first | promise_flagged: true}}
    end
  end

  # The flag follows the answer that is actually delivered, so the two can never
  # disagree about whether the words that were kept carry a promise.
  defp settle(answered) do
    case promise_check(answered.text) do
      :clean -> %{answered | promise_flagged: false}
      {:promise, _patterns} -> %{answered | promise_flagged: true}
    end
  end

  defp attempt(user, system, opts) do
    case llm().answer(system, user, llm_opts(opts)) do
      {:ok, %{text: text} = answered} when is_binary(text) ->
        if String.trim(text) == "" do
          {:error, :empty_answer}
        else
          {:ok, Map.put(answered, :promise_flagged, false)}
        end

      {:ok, _other} ->
        {:error, :empty_answer}

      {:error, code} when is_atom(code) ->
        {:error, code}

      _other ->
        {:error, :unavailable}
    end
  catch
    # `rescue` alone would miss an exit — and a broker call to a connection that
    # is not there exits.
    kind, reason -> {:error, crash_code(kind, reason)}
  end

  # The caller may state what the work needs — a narration has no screen waiting on it and
  # can wait far longer than an answer to a captured reflection — so a `:budget_ms` override
  # is merged in. Everything else about the request stays here, in one place.
  defp llm_opts(overrides) do
    settings = config()

    Keyword.merge(
      [
        subject: settings[:subject],
        status_subject: settings[:status_subject],
        model_type: settings[:model_type],
        lane: settings[:lane],
        max_tokens: settings[:max_tokens],
        budget_ms: settings[:budget_ms],
        poll_ms: settings[:poll_ms],
        submit_timeout_ms: settings[:submit_timeout_ms],
        status_timeout_ms: settings[:status_timeout_ms]
      ],
      overrides
    )
  end

  @doc """
  What she was asked, and what she wrote — the message the model receives.

  Her question is included when the screen sent one, because "she wrote this"
  and "she wrote this *in answer to that*" are different things to respond to.
  """
  def prompt_for(%Reflection{} = row) do
    case row.prompt do
      prompt when is_binary(prompt) and prompt != "" ->
        "She was answering this question:\n\n#{prompt}\n\nShe wrote:\n\n#{row.text}"

      _none ->
        "She wrote:\n\n#{row.text}"
    end
  end

  @doc "The instruction the model is given about its own behaviour."
  def system_prompt, do: @system_prompt

  @doc """
  Does this answer promise something?

  Returns `:clean`, or `{:promise, patterns}` naming the *patterns* that matched
  — not the sentences, which are the model's words and stay in the answer.
  """
  def promise_check(text) when is_binary(text) do
    matched = Enum.filter(@promise_patterns, &Regex.match?(&1, text))

    case matched do
      [] -> :clean
      found -> {:promise, Enum.map(found, &Regex.source/1)}
    end
  end

  def promise_check(_other), do: :clean

  @doc "A refusal or a failure, as a sentence someone could read."
  def explain(:unasked), do: "answering is switched off, so nothing was asked"
  def explain(:disabled), do: "the companion is not answering reflections at the moment"
  def explain(:timeout), do: "the model did not finish in time"
  def explain(:unavailable), do: "the model could not be reached"
  def explain(:empty_answer), do: "the model answered with nothing"
  def explain(:model_failed), do: "the model reported a failure"
  def explain(:not_found), do: "there is no reflection with that id"
  def explain(_other), do: "the companion could not answer"

  defp describe_crash(kind, %{__struct__: module}), do: "#{kind} in #{inspect(module)}"
  defp describe_crash(kind, reason) when is_atom(reason), do: "#{kind}: #{reason}"
  defp describe_crash(kind, _other), do: "#{kind}"

  defp crash_code(_kind, _reason), do: :unavailable
end
