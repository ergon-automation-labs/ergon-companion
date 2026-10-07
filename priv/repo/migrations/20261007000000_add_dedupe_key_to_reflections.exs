defmodule BotArmyCompanion.Repo.Migrations.AddDedupeKeyToReflections do
  @moduledoc """
  A client-supplied idempotency key for captured reflections.

  On 2026-10-05 one press of a reflect screen's submit produced **two rows 30 ms
  apart** for the same line, and two answers were asked for. The store could not
  tell that double-send from two identical reflections, because it had nothing to
  go on but the words themselves — and two identical lines a minute apart is a
  thing she might really write, so guessing from the text would have been worse
  than the bug.

  A key the *caller* mints per draft lets the store tell them apart, and the
  unique index is what makes the answer exact under a race: the second insert
  loses, and the row it lost to is the row that is returned. That is a better
  answer than reading first and writing second, which has a window between the
  two where both writers see nothing.

  Nullable on purpose: every writer that has no key (the `events.reflection.
  captured` path, older screens, a hand-written probe) must keep working exactly
  as before. Postgres allows any number of NULLs in a unique index, so an absent
  key is not a collision — only a *stated* key can collide, and only with itself.
  """

  use Ecto.Migration

  def change do
    alter table(:reflections) do
      add(:dedupe_key, :string,
        comment: "The caller's idempotency key for this capture, or NULL when it sent none"
      )
    end

    create(
      unique_index(:reflections, [:dedupe_key],
        name: :reflections_dedupe_key_index,
        comment: "One row per stated key; NULLs do not collide, so keyless writers are unaffected"
      )
    )
  end
end
