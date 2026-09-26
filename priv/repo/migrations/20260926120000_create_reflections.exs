defmodule BotArmyCompanion.Repo.Migrations.CreateReflections do
  @moduledoc """
  Her captured reflections — the words she wrote on a reflect screen.

  `captured_at` holds the publisher's own timestamp and is nullable on purpose:
  a payload without one, or with one that cannot be read, is stored as `nil`
  rather than replaced by the time we happened to receive it. "When she wrote
  it" and "when we heard it" are two different facts, and only one of them is
  ours to state. `inserted_at` carries the second.
  """

  use Ecto.Migration

  def change do
    create table(:reflections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:text, :text,
        null: false,
        comment: "Her words, exactly as they arrived — never trimmed or rounded"
      )

      add(:prompt, :text, comment: "The question she was answering, when the publisher sent one")

      add(:captured_at, :utc_datetime_usec,
        comment: "The publisher's timestamp, or NULL when it did not say or could not be read"
      )

      timestamps(type: :utc_datetime_usec)
    end

    # Reads are "the most recent ones", so the index is on arrival order.
    create(index(:reflections, [:inserted_at]))
  end
end
