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

  @doc "The longest reflection the store will take, in characters."
  def max_text, do: Reflection.max_text()

  @doc "How many reflections `list/1` returns when the caller does not say."
  def default_limit, do: @default_limit

  @doc "The largest `limit` `list/1` will honour."
  def max_limit, do: @max_limit

  @doc """
  Store one reflection.

  Accepts the shape the reflect screens publish — `%{"text" => …, "prompt" => …,
  "timestamp" => …}`. Refusals come from `prepare/1`; the words are stored
  exactly as they arrived.
  """
  def capture(attrs) do
    with {:ok, prepared} <- prepare(attrs) do
      case Repo.insert(Reflection.changeset(%Reflection{}, prepared)) do
        {:ok, row} ->
          {:ok, view(row)}

        {:error, changeset} ->
          # prepare/1 should have caught every one of these; if the changeset
          # still refuses, say so rather than pretending the reflection landed.
          # The errors carry counts, not her text.
          Logger.warning("Reflections.capture: changeset refused: #{inspect(changeset.errors)}")
          {:error, :invalid}
      end
    end
  end

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

  A missing or malformed id is `{:error, :not_found}` — never a crash, and never
  a nil-shaped "found".
  """
  def get(id) when is_binary(id) do
    if Regex.match?(@uuid, id) do
      case Repo.get(Reflection, id) do
        nil -> {:error, :not_found}
        row -> {:ok, view(row)}
      end
    else
      {:error, :not_found}
    end
  end

  def get(_other), do: {:error, :not_found}

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
      "chars" => String.length(row.text || "")
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
  def explain(:not_found), do: "there is no reflection with that id"
  def explain(:invalid), do: "the store refused that reflection"
  def explain(:store_failed), do: "the reflection store could not be reached"
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
