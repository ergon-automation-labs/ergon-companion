defmodule BotArmyCompanion.Repo.Migrations.AddAnswerToReflections do
  @moduledoc """
  What the companion said back.

  Her reflection used to be a row that only stored words in. Now the companion
  answers it, and the answer arrives **later** — the uncensored local model can
  take a minute or more — so the row has to be able to say which of those things
  is true at the moment you read it:

  * `pending`   — the words are stored, the answer is being written
  * `answered`  — `answer_text` holds what it said, `answered_at` says when we heard it
  * `failed`    — it tried and could not; `answer_error` carries a reason *code*
  * `unasked`   — answering was switched off, and the row does not pretend otherwise

  `answer_error` holds a code, never the provider's own message: that message can
  quote the request, and the request contains her words.

  The default is `pending` rather than `unasked` because the migration runs on a
  store whose writer will answer: a row that arrives without a state is a row
  whose answer is coming.
  """

  use Ecto.Migration

  def change do
    alter table(:reflections) do
      add(:answer_state, :string,
        null: false,
        default: "pending",
        comment: "pending | answered | failed | unasked — see the moduledoc"
      )

      add(:answer_text, :text, comment: "What the companion said back, when it said anything")

      add(:answered_at, :utc_datetime_usec,
        comment: "When the store learned the answer — not when the model produced it"
      )

      add(:answer_model, :string,
        comment: "Which model actually answered; the configured one is only a request"
      )

      add(:answer_error, :string,
        comment: "A reason *code* (timeout, unavailable, …) — never the provider's message"
      )

      add(:promise_flagged, :boolean,
        null: false,
        default: false,
        comment: "The model promised something; kept visible rather than hidden"
      )
    end

    # "Which reflections are still waiting for an answer?" is a real question,
    # asked by anyone who wonders whether the answer side is awake.
    create(index(:reflections, [:answer_state]))
  end
end
