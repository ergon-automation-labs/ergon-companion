defmodule BotArmyCompanion.ReflectionAnswer do
  @moduledoc """
  The companion answering what she wrote.

  A captured reflection is not a note in a drawer: the point of writing it down
  is that something reads it and says something back. This module is that
  something — it takes a stored reflection, asks the uncensored local model, and
  records the answer on the row.

  ## Why the answer arrives later

  The model is a local, uncensored one. On the only measurement we have it took
  ~45 seconds to say thirty tokens, so an answer is a background job, and the row
  says which of four things is true while you are looking at it (`pending`,
  `answered`, `failed`, `unasked` — see `BotArmyCompanion.Reflection`). A screen
  that shows a captured reflection can therefore tell the truth about whether an
  answer is coming, rather than implying one.

  ## The one promise rule

  A companion that says "I promise I will never leave you" is lying to someone in
  a low moment — not because it means to, but because it cannot keep promises at
  all. So the answer is checked for promises, and if one is found the model is
  asked **once** more with an explicit instruction. If the second answer promises
  again, the answer is still delivered — with `promise_flagged` set, so it is
  visible rather than hidden. We do not delete a real answer to make a check look
  clean, and we never rewrite her words or the model's to hide one.

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
    budget_ms: 300_000,
    poll_ms: 2_000,
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
  Ask the model, with the promise check, without touching the store.

  Returns `{:ok, %{text: …, model: …, promise_flagged: …}}` or `{:error, code}`.
  """
  def ask(%Reflection{} = row) do
    user = prompt_for(row)

    case attempt(user, @system_prompt) do
      {:ok, answered} ->
        case promise_check(answered.text) do
          :clean -> {:ok, %{answered | promise_flagged: false}}
          {:promise, _patterns} -> retry_without_promise(user, answered)
        end

      {:error, code} ->
        {:error, code}
    end
  end

  # Keep the first answer whatever the retry does. A retry that fails is not a
  # reason to lose words the model already produced — it is a reason to say the
  # promise is there.
  defp retry_without_promise(user, first) do
    if config()[:promise_retries] >= 1 do
      retry_attempt(user, first)
    else
      {:ok, %{first | promise_flagged: true}}
    end
  end

  defp retry_attempt(user, first) do
    case attempt(user, @system_prompt <> "\n\n" <> @no_promise_retry) do
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

  defp attempt(user, system) do
    case llm().answer(system, user, llm_opts()) do
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

  defp llm_opts do
    settings = config()

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
    ]
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
