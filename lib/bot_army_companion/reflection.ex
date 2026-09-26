defmodule BotArmyCompanion.Reflection do
  @moduledoc """
  One thing she wrote, and what we know about it.

  This is *her* reflection, not Eir's: the companion's own reflections are
  LLM-written angles stored as PARA documents and browsed through
  `companion.observations.*`. These rows are the words she typed on a reflect
  screen, kept exactly as they arrived.

  `captured_at` is the publisher's claim and may be `nil`; `inserted_at` is
  when the store heard it. A reader that needs a time should prefer
  `captured_at` and fall back to `inserted_at`, saying which it used — the two
  are not interchangeable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  # The one place the ceiling is written down. The service reads it from here
  # so a validation refusal and the changeset can never disagree.
  @max_text 4_000

  # The four things a row can truthfully say about its answer. They live in one
  # place because the migration, the changeset, the service and the wire all
  # mean the same four words — and copies of a vocabulary drift.
  @answer_states ~w(pending answered failed unasked)

  schema "reflections" do
    field(:text, :string)
    field(:prompt, :string)
    field(:captured_at, :utc_datetime_usec)

    # The answer side. See the migration for what each state means.
    field(:answer_state, :string, default: "pending")
    field(:answer_text, :string)
    field(:answered_at, :utc_datetime_usec)
    field(:answer_model, :string)
    field(:answer_error, :string)
    field(:promise_flagged, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The longest reflection the store will take, in characters."
  def max_text, do: @max_text

  @doc "The answer states a row may carry, in one place."
  def answer_states, do: @answer_states

  @doc "Whether a string names one of the answer states."
  def answer_state?(state), do: state in @answer_states

  @doc """
  Second line of defence, behind `BotArmyCompanion.Reflections.prepare/1`.

  The database holds the line for anything that walks past both: `text` is
  `NOT NULL`, so a writer that skips this changeset gets an error rather than a
  wordless row.
  """
  def changeset(reflection, attrs) do
    reflection
    |> cast(attrs, [:text, :prompt, :captured_at, :answer_state])
    |> validate_required([:text])
    |> validate_length(:text, max: @max_text)
    |> validate_inclusion(:answer_state, @answer_states)
  end

  @doc """
  The answer arriving, on a row that already exists.

  Separate from `changeset/2` on purpose. That one guards her words on the way
  in and must not be re-run to record what the companion said: re-casting `text`
  on an update would re-validate a row that is already stored, and a validation
  failure there would lose the answer of a reflection we already hold.

  The state is checked against `answer_states/0` for the same reason the database
  has a default: a typo in a state is a row that cannot be read, not a new state.
  """
  def answer_changeset(reflection, attrs) do
    reflection
    |> cast(attrs, [
      :answer_state,
      :answer_text,
      :answered_at,
      :answer_model,
      :answer_error,
      :promise_flagged
    ])
    |> validate_inclusion(:answer_state, @answer_states)
  end
end
