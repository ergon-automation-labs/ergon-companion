defmodule BotArmyCompanion.Repo.Migrations.SeedReflectionAnglesWinsTrustRest do
  use Ecto.Migration

  @moduledoc """
  Data migration: inserts reflection angles 8 (wins/celebration), 9 (system
  trust trend), and 10 (rest/disconnection) into companion_thoughts.

  These angles previously depended entirely on Salt's `companion_bot_seed_thoughts`
  cmd.run step (BotArmyCompanion.Release.seed/0) — a step that only warns and
  continues on failure, isn't part of the migration gate, and left no trace in
  the deploy log. After deploying v0.1.24 the rows never actually landed. Real
  migrations run through the same hard-gated path as schema changes
  (`companion_bot_run_migrations` blocks deployment on failure), so this is
  guaranteed to apply exactly once. Release.migrate/0 now also calls seed/0
  after running migrations, so future edits to seed_default_thoughts/0 get the
  same guarantee — this migration exists for these three specific rows so they
  land even on databases where that changed sequencing hasn't run yet.
  """

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    thoughts = [
      {
        8,
        "What's a recent win — a fix shipped, a fast diagnosis, an outreach reply, anything that actually happened — that hasn't been acknowledged? Celebrate the action taken, not the outcome. One paragraph, warm.",
        8,
        ["wins", "celebration", "adhd"]
      },
      {
        9,
        "Is Abby's trust in the Bot Army system growing or eroding right now? Is she fighting the same fire repeatedly, or genuinely making progress? What would rebuild confidence if it's slipping? One paragraph, honest.",
        8,
        ["trust", "reliability", "system-state"]
      },
      {
        10,
        "When did Abby last fully disconnect — not rest-shaped busywork, actual stopping? Is she protecting recovery time or pretending to? One paragraph, direct but kind.",
        8,
        ["rest", "boundaries", "adhd"]
      }
    ]

    Enum.each(thoughts, fn {angle, query, priority, tags} ->
      repo().query!(
        """
        INSERT INTO companion_thoughts (id, angle, query, active, priority, tags, inserted_at, updated_at)
        VALUES ($1, $2, $3, true, $4, $5, $6, $6)
        ON CONFLICT (angle) DO UPDATE
          SET query = EXCLUDED.query, priority = EXCLUDED.priority, tags = EXCLUDED.tags, updated_at = EXCLUDED.updated_at
        """,
        [Ecto.UUID.generate(), angle, query, priority, tags, now]
      )
    end)
  end

  def down do
    repo().query!("DELETE FROM companion_thoughts WHERE angle IN (8, 9, 10)")
  end
end
