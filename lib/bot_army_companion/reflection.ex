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

  schema "reflections" do
    field(:text, :string)
    field(:prompt, :string)
    field(:captured_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The longest reflection the store will take, in characters."
  def max_text, do: @max_text

  @doc """
  Second line of defence, behind `BotArmyCompanion.Reflections.prepare/1`.

  The database holds the line for anything that walks past both: `text` is
  `NOT NULL`, so a writer that skips this changeset gets an error rather than a
  wordless row.
  """
  def changeset(reflection, attrs) do
    reflection
    |> cast(attrs, [:text, :prompt, :captured_at])
    |> validate_required([:text])
    |> validate_length(:text, max: @max_text)
  end
end
