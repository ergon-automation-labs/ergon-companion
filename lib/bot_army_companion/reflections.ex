defmodule BotArmyCompanion.Reflections do
  @moduledoc """
  Her captured reflections: the words she wrote on the reflect screens.

  ## What this is, and what it is not

  The companion already holds *Eir's* reflections — LLM-written angles kept as
  PARA documents and browsed through `companion.observations.*`. Those are
  Eir's words about her. These are **her** words, and they had no home at all:
  the dashboard's reflect screens published `events.reflection.captured` to a
  subject with no subscriber, so the text went nowhere while the screen said
  "captured". Storing it is the whole of this module's job.

  ## The two paths in

  * `capture/1` — validates a payload and stores it. It is called both by the
    `companion.reflections.capture` request (which can *answer*, so a screen can
    stop claiming success it cannot know about) and by the
    `events.reflection.captured` subscription (the existing screens, unchanged).
  * `list/1` and `get/1` — read it back, newest first.

  ## Refusal discipline

  * A payload without usable words is refused (`:no_text`), never stored. An
    over-long reflection is refused with the ceiling in the reason
    (`{:too_long, max}`) rather than silently truncated: cutting her sentence
    in half and keeping the half is not keeping her words.
  * An unreadable timestamp is not a reason to lose the words. It is stored as
    `nil`, which says "the publisher did not tell us when" — a fact — where
    substituting our arrival time would be a guess dressed as knowledge.
  * A failed **read** is `{:error, reason}`, never `[]`. An empty list means the
    store answered and there is nothing in it.

  ## One press is one reflection

  `capture/2` answers `{:ok, view, :created}` or `{:ok, view, :existing}`, and
  the difference is not decoration: a caller that cannot tell a double-send from
  a second reflection will store two rows and ask for two answers. A caller that
  sends the same `dedupe_key` twice gets the row it already has, and must not ask
  the companion again. A caller that sends no key keeps the old behaviour exactly
  — one row per call — which is what every older screen does.
  """

  import Ecto.Query

  require Logger

  alias BotArmyCompanion.Reflection
  alias BotArmyCompanion.Repo

  @default_limit 20
  @max_limit 200

  # A well-formed UUID, so a malformed id is a refusal rather than a cast error
  # from the driver. Same regex the fleet uses elsewhere.
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # A dedupe key is a short handle the caller mints, not a payload. The ceiling
  # is generous, and it is also load-bearing: a key longer than a btree entry can
  # hold would make the *insert* fail with a driver error rather than a refusal,
  # which is how her words would get lost to a malformed key.
  @max_dedupe_key 200

  # The two codes that mean *nobody ever answered*: the request never landed, or
  # the model did not finish inside the lane's budget. Both are worth asking
  # again, and both are facts about the journey rather than about the answer.
  #
  # Deliberately absent: `model_failed` and `empty_answer` are the model's own
  # verdicts about a generation. Asking the same model the same question again is
  # not a retry, it is a repeat, and it would spend an hour to hear it twice.
  @reofferable_errors ~w(unavailable timeout)

  @doc "The longest reflection the store will take, in characters."
  def max_text, do: Reflection.max_text()

  @doc "How many reflections `list/1` returns when the caller does not say."
  def default_limit, do: @default_limit

  @doc "The largest `limit` `list/1` will honour."
  def max_limit, do: @max_limit

  @doc """
  Store one reflection.

  Accepts the shape the reflect screens publish — `%{"text" => …, "prompt" => …,
  "timestamp" => …, "dedupe_key" => …}`. Refusals come from `prepare/1`; the words
  are stored exactly as they arrived.

  Answers `{:ok, view, :created}` when a reflection was written, and
  `{:ok, view, :existing}` when the caller's `dedupe_key` already named one — in
  which case nothing was written and the words in `view` are the ones already on
  the row. The caller must ask the companion only for `:created`; two answers for
  one line is the bug this key exists to stop.
  """
  def capture(attrs, opts \\ []) do
    with {:ok, prepared} <- prepare(attrs),
         {:ok, answer_state} <- take_answer_state(Keyword.get(opts, :answer_state, "pending")) do
      attrs =
        prepared
        |> Map.put(:answer_state, answer_state)
        |> Map.put(:dedupe_key, dedupe_key(attrs))

      insert(attrs, attrs.dedupe_key)
    end
  end

  # No key: the writer stated no identity for this capture, so every call is its
  # own reflection. This is the path every older screen takes.
  defp insert(attrs, nil), do: insert_new(attrs)

  defp insert(attrs, key) do
    case Repo.insert(Reflection.changeset(%Reflection{}, attrs)) do
      {:ok, row} ->
        {:ok, view(row), :created}

      {:error, changeset} ->
        if dedupe_collision?(changeset) do
          existing(attrs, key, changeset)
        else
          refuse(changeset)
        end
    end
  end

  # Somebody got there first with this key — under a race, possibly microseconds
  # ago. The row is the answer, whichever writer wrote it, and it is not asked
  # for a second answer.
  defp existing(attrs, key, changeset) do
    case Repo.get_by(Reflection, dedupe_key: key) do
      nil ->
        # The colliding row is gone (deleted between the two statements). Saying
        # "already here" about a row nobody can read would be a small lie; the
        # changeset that refused is the truth.
        refuse(changeset)

      row ->
        if same_words?(row, attrs) do
          {:ok, view(row), :existing}
        else
          # The key was minted for different words. A key is a handle, never a
          # filter over her words: storing this one *without* the key costs one
          # duplicate row in a case that should not happen, where dropping it
          # would cost her a sentence.
          Logger.warning(
            "Reflections.capture: a dedupe key was reused for different words; storing without it"
          )

          insert_new(Map.put(attrs, :dedupe_key, nil))
        end
    end
  end

  defp insert_new(attrs) do
    case Repo.insert(Reflection.changeset(%Reflection{}, attrs)) do
      {:ok, row} -> {:ok, view(row), :created}
      {:error, changeset} -> refuse(changeset)
    end
  end

  # Two refusals that look alike and are not: "the store would not take this" is
  # not the same as "the store is down", and the second one is not a refusal at
  # all. Here we are in the first case only — the database answered.
  defp refuse(changeset) do
    # prepare/1 should have caught every one of these; if the changeset still
    # refuses, say so rather than pretending the reflection landed. The errors
    # carry counts, not her text.
    Logger.warning("Reflections.capture: changeset refused: #{inspect(changeset.errors)}")
    {:error, :invalid}
  end

  defp dedupe_collision?(changeset), do: Keyword.has_key?(changeset.errors, :dedupe_key)

  # The words, and the question they answered. The moment is deliberately not
  # compared: a caller that sends the same draft twice may well stamp the second
  # send with a fresh time, and the same words a millisecond later are still the
  # same reflection.
  defp same_words?(row, attrs), do: row.text == attrs.text and row.prompt == attrs.prompt

  @doc """
  The decision, without the store.

  Returns `{:ok, attrs}` ready for a changeset, or `{:error, reason}`. Public
  and pure so the decisions can be tested without a database, and so a caller
  can ask "would this be accepted?" before writing anything.
  """
  def prepare(attrs) when is_map(attrs) do
    with {:ok, text} <- take_text(attrs),
         {:ok, prompt} <- take_prompt(attrs),
         {:ok, captured_at} <- take_captured_at(attrs) do
      {:ok, %{text: text, prompt: prompt, captured_at: captured_at}}
    end
  end

  def prepare(_other), do: {:error, :not_a_map}

  @doc """
  The idempotency key a payload carries, or `nil` when it carries none.

  Public and pure, like `prepare/1`, and for the same reason: this is a decision
  worth proving without a database. It is also the one place the wire spelling
  (`"dedupe_key"`) is written down for the store.

  A key is **metadata**, so a malformed one costs the caller its key and never
  her words — the same rule the timestamp gets, for the same reason. An absent,
  empty, non-text, or over-long key is simply no key: the writer stated no
  identity for this capture, and every call stands on its own.
  """
  def dedupe_key(attrs) when is_map(attrs) do
    case fetch(attrs, "dedupe_key") do
      key when is_binary(key) ->
        key = String.trim(key)

        if key != "" and String.length(key) <= @max_dedupe_key, do: key, else: nil

      _absent_or_not_text ->
        nil
    end
  end

  def dedupe_key(_other), do: nil

  @doc """
  Record what the companion said back — or that it could not say anything.

  `answer_error` is the *code* the answer side gave us, never the provider's own
  message. A provider message can quote the request, and the request is her text.
  """
  def record_answer(%Reflection{} = row, {:ok, %{text: text} = answered}) do
    update_answer(row, %{
      answer_state: "answered",
      answer_text: text,
      answered_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      answer_model: Map.get(answered, :model),
      answer_error: nil,
      promise_flagged: Map.get(answered, :promise_flagged) == true
    })
  end

  def record_answer(%Reflection{} = row, {:error, reason}) do
    update_answer(row, %{
      answer_state: "failed",
      answer_error: code_for(reason)
    })
  end

  defp update_answer(row, attrs) do
    case Repo.update(Reflection.answer_changeset(row, attrs)) do
      {:ok, updated} -> {:ok, view(updated)}
      {:error, _changeset} -> {:error, :invalid}
    end
  end

  # An answer's failure is one of the codes the answer side can produce; anything
  # else is a failure we cannot name, and says so rather than borrowing a name.
  defp code_for(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for(_other), do: "unavailable"

  @doc """
  Ask the companion to answer a stored reflection **again**, when nobody ever did.

  This exists because a whole-fleet NATS blip is not an answer. On 2026-10-05 a
  line she wrote was handed to the model, the model was still generating, and
  three failed status reads in a row turned the row into `failed`/
  `unavailable` — a turn burned by the transport, with no way back. A failure is
  allowed to be permanent; being permanent *by omission* is not.

  Narrow on purpose:

  * only a row whose answer `failed` is considered at all;
  * only when the failure was on the way to the model or inside its budget
    (`@reofferable_errors`) — refusals and model verdicts are not retried;
  * `answered` is never re-opened, because a second answer to the same words is
    not a repair, it is a duplicate she would have to read twice.

  `answer_state` in `opts` is the state to open the row with — the caller passes
  `unasked` when the answer side is switched off, so a re-offer cannot leave a row
  saying "pending" that nothing is going to answer.
  """
  def reoffer(id, opts \\ []) do
    with {:ok, row} <- find(id),
         {:ok, answer_state} <- take_answer_state(Keyword.get(opts, :answer_state, "pending")),
         :ok <- reofferable(row) do
      update_answer(row, %{
        answer_state: answer_state,
        answer_text: nil,
        answered_at: nil,
        answer_model: nil,
        answer_error: nil,
        promise_flagged: false
      })
    end
  end

  @doc """
  Whether a row may be offered to the companion again — `:ok`, or why not.

  Public and pure: the rule is the interesting part of a re-offer, and a test can
  prove it without a database.
  """
  def reofferable(%Reflection{answer_state: "failed", answer_error: code})
      when code in @reofferable_errors,
      do: :ok

  def reofferable(%Reflection{answer_state: "failed", answer_error: code}),
    do: {:error, {:answer_was_not_transport, code}}

  def reofferable(%Reflection{answer_state: state}), do: {:error, {:not_failed, state}}
  def reofferable(_other), do: {:error, :not_found}

  defp take_answer_state(state) when is_binary(state) do
    if Reflection.answer_state?(state), do: {:ok, state}, else: {:error, :bad_answer_state}
  end

  defp take_answer_state(_other), do: {:error, :bad_answer_state}

  @doc """
  The most recent reflections, newest first.

  A bad limit is refused (`:bad_limit`) rather than quietly replaced by the
  default: a caller that asked for something incoherent should hear about it,
  not receive twenty rows and believe that is what it asked for.
  """
  def list(limit) do
    with {:ok, limit} <- take_limit(limit) do
      views =
        Reflection
        |> order_by(desc: :inserted_at)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(&view/1)

      {:ok, views}
    end
  end

  @doc """
  One reflection by id.

  Three different things used to answer "no such reflection", and they are not
  the same fact. A request that carried no id, and a request that carried
  something which cannot be an id, never reached the store at all — answering
  those `:not_found` was a claim about the store's contents that nobody had
  checked. Only a well-formed id the store does not hold is a `:not_found`.
  """
  def get(id) do
    case find(id) do
      {:ok, row} -> {:ok, view(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  # One owner for "how an id reaches the store", so a read and a re-offer cannot
  # disagree about what a missing, malformed, or absent id means.
  defp find(id) when is_binary(id) do
    case take_id(id) do
      {:ok, uuid} ->
        case Repo.get(Reflection, uuid) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find(_other), do: {:error, :missing_id}

  @doc """
  A reflection, as the wire sees it.

  `chars` is derived from the text rather than stored beside it, so it can never
  drift from the words it claims to count. `captured_at` is the publisher's
  claim and `stored_at` is ours; either may be `nil`, and a reader that shows
  only one should say which.
  """
  def view(%Reflection{} = row) do
    %{
      "id" => row.id,
      "text" => row.text,
      "prompt" => row.prompt,
      "captured_at" => iso8601(row.captured_at),
      "stored_at" => iso8601(row.inserted_at),
      "chars" => String.length(row.text || ""),
      "answer" => answer_view(row)
    }
  end

  # The answer, in the same shape whether it exists or not: a reader never has to
  # ask whether a key is there. `model` is the model that answered, which is not
  # necessarily the one that was configured — and `answered_at` is when the store
  # learned it, not when the model produced it, because only the first is a fact
  # we hold.
  defp answer_view(%Reflection{} = row) do
    %{
      "state" => row.answer_state || "pending",
      "text" => row.answer_text,
      "model" => row.answer_model,
      "answered_at" => iso8601(row.answered_at),
      "promise_flagged" => row.promise_flagged == true,
      "error" => row.answer_error
    }
  end

  @doc """
  A refusal, as a sentence someone could read.
  """
  def explain(:no_text), do: "a reflection needs words in it"

  def explain({:too_long, max}),
    do: "a reflection may hold at most #{max} characters"

  def explain(:bad_prompt), do: "the prompt must be text when it is sent"
  def explain(:not_a_map), do: "a reflection arrives as an object with text in it"
  def explain(:bad_limit), do: "a limit must be a whole number between 1 and #{@max_limit}"
  def explain(:bad_answer_state), do: "an answer state must be one the store knows"
  def explain(:not_found), do: "there is no reflection with that id"
  def explain(:missing_id), do: "a reflection id is required"
  def explain(:invalid_id), do: "a reflection id is a uuid, and that is not one"
  def explain(:invalid), do: "the store refused that reflection"
  def explain(:store_failed), do: "the reflection store could not be reached"

  # A re-offer that is refused has to say *which* of the facts stopped it: a line
  # the companion already answered, one it is answering now, one nobody asked it
  # about, and one the model could not answer — four different sentences, because
  # "no" on its own teaches the caller nothing.
  def explain({:not_failed, "answered"}), do: "that reflection already has an answer"
  def explain({:not_failed, "pending"}), do: "the companion is already answering that reflection"

  def explain({:not_failed, "unasked"}),
    do: "the companion was never asked to answer that reflection"

  def explain({:not_failed, _state}), do: "that reflection is not a failed answer"

  def explain({:answer_was_not_transport, code}),
    do: "that reflection reached the model and failed there (#{code}); asking again is a repeat"

  def explain(_other), do: "the reflection store could not answer"

  # --- taking the fields apart ------------------------------------------------

  defp take_text(attrs) do
    case fetch(attrs, "text") do
      text when is_binary(text) ->
        cond do
          String.trim(text) == "" -> {:error, :no_text}
          String.length(text) > max_text() -> {:error, {:too_long, max_text()}}
          true -> {:ok, text}
        end

      _absent_or_not_text ->
        {:error, :no_text}
    end
  end

  defp take_prompt(attrs) do
    case fetch(attrs, "prompt") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      prompt when is_binary(prompt) -> {:ok, prompt}
      _other -> {:error, :bad_prompt}
    end
  end

  # An absent, unreadable, or non-text timestamp yields nil. It is metadata; her
  # words are the payload, and losing them because a timestamp was malformed
  # would be the store choosing the least important field.
  defp take_captured_at(attrs) do
    case fetch(attrs, "timestamp") do
      nil ->
        {:ok, nil}

      ts when is_binary(ts) and ts != "" ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :microsecond)}
          {:error, _reason} -> {:ok, nil}
        end

      "" ->
        {:ok, nil}

      _other ->
        {:ok, nil}
    end
  end

  # Absent and malformed are different refusals on purpose: the caller that sent
  # nothing can fix its call, while the caller that sent a UUID-shaped id learns
  # only that the store does not have it.
  defp take_id(""), do: {:error, :missing_id}

  defp take_id(id) do
    if Regex.match?(@uuid, id), do: {:ok, id}, else: {:error, :invalid_id}
  end

  defp take_limit(nil), do: {:ok, @default_limit}

  defp take_limit(limit) when is_integer(limit) do
    if limit >= 1 and limit <= @max_limit, do: {:ok, limit}, else: {:error, :bad_limit}
  end

  # A JSON integer arrives as an integer, but a hand-typed payload or a query
  # string may carry "5". A whole number written as text is still a whole
  # number; anything else is refused.
  defp take_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {n, ""} -> take_limit(n)
      _other -> {:error, :bad_limit}
    end
  end

  defp take_limit(_other), do: {:error, :bad_limit}

  # The wire is string-keyed: both callers hand this module a decoded JSON
  # object. A second, atom-keyed shape would be a vocabulary with two spellings.
  defp fetch(attrs, key), do: Map.get(attrs, key)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
