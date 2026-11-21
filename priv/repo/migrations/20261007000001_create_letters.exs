defmodule BotArmyCompanion.Repo.Migrations.CreateLetters do
  @moduledoc """
  The pen-pal thread between Abby and Eir.

  `body` is a sealed envelope (`BotArmyCompanion.Sealed`, AES-256-GCM), never the text: the
  database holds ciphertext, so a dump, a backup or a stray `SELECT` shows no letters. The
  envelope is bound to the letter's id, so a body cannot be moved onto another row.

  An Abby letter carries when its reply is due (`deliver_at`, from `Letters.Timing`) and
  where that reply stands (`status`): `waiting` until it is claimed, `writing` while one worker
  holds it (the claim is one atomic UPDATE, so a restart or a second node cannot write a second
  reply), `answered` once Eir's letter exists (`reply_to_id` on that letter points back),
  `failed` when no reply could be made. Eir's own letters have status `none`. There is no
  read/unread column on purpose: nothing here counts what she has not opened.

  `kind` is `normal`, or `safety` for the fixed crisis reply (`Letters.Compose.safety_reply/0`).
  It is recorded, not inferred from the wording, so the letter after a safety reply can open with
  a gentle check-in even if the safety wording is edited later.

  `dedupe_key` is the sender's request id: a second send of the same press (a double tap, a
  reconnect, a replayed request) finds the first letter instead of making a second one and
  asking the model for a second reply. The index is unique and partial, because a check-then-write
  cannot be raced safely.
  """

  use Ecto.Migration

  def change do
    create table(:letters, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:author, :string, null: false, comment: "abby | eir")

      add(:body, :map,
        null: false,
        comment: "A sealed envelope, never the text itself"
      )

      add(:reply_to_id, references(:letters, type: :binary_id, on_delete: :nilify_all),
        comment: "On an eir letter: the abby letter it answers"
      )

      add(:kind, :string,
        null: false,
        default: "normal",
        comment: "normal | safety (the fixed crisis reply)"
      )

      add(:status, :string,
        null: false,
        default: "none",
        comment:
          "On an abby letter: waiting | writing | answered | failed. On an eir letter: none"
      )

      add(:dedupe_key, :string,
        comment: "The sender's request id; a repeat finds the first letter"
      )

      add(:deliver_at, :utc_datetime_usec,
        comment: "On a waiting abby letter: when the reply is due (UTC)"
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:letters, :letters_author_known, check: "author in ('abby', 'eir')"))

    create(
      constraint(:letters, :letters_status_known,
        check: "status in ('none', 'waiting', 'writing', 'answered', 'failed')"
      )
    )

    create(constraint(:letters, :letters_kind_known, check: "kind in ('normal', 'safety')"))

    create(unique_index(:letters, [:dedupe_key], where: "dedupe_key is not null"))
    create(index(:letters, [:inserted_at]))
    create(index(:letters, [:status, :deliver_at]))
    create(index(:letters, [:reply_to_id]))
  end
end
