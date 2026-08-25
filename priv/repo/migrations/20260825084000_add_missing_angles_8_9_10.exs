defmodule BotArmyCompanion.Repo.Migrations.AddMissingAngles8_9_10 do
  use Ecto.Migration

  def up do
    now = DateTime.utc_now()

    rows = [
      {
        Ecto.UUID.generate(),
        8,
        "What's a recent win — a fix shipped, a fast diagnosis, an outreach reply, anything that actually happened — that hasn't been acknowledged? Celebrate the action taken, not the outcome. One paragraph, warm.",
        true,
        8,
        ["wins", "celebration", "adhd"],
        now,
        now
      },
      {
        Ecto.UUID.generate(),
        9,
        "Is Abby's trust in the Bot Army system growing or eroding right now? Is she fighting the same fire repeatedly, or genuinely making progress? What would rebuild confidence if it's slipping? One paragraph, honest.",
        true,
        8,
        ["trust", "reliability", "system-state"],
        now,
        now
      },
      {
        Ecto.UUID.generate(),
        10,
        "When did Abby last fully disconnect — not rest-shaped busywork, actual stopping? Is she protecting recovery time or pretending to? One paragraph, direct but kind.",
        true,
        8,
        ["rest", "boundaries", "adhd"],
        now,
        now
      }
    ]

    repo().insert_all(
      "companion_thoughts",
      rows,
      columns: [:id, :angle, :query, :active, :priority, :tags, :inserted_at, :updated_at],
      on_conflict: {:replace, [:query, :priority, :tags, :updated_at]},
      conflict_target: :angle
    )
  end

  def down do
    repo().delete_all("companion_thoughts WHERE angle IN (8, 9, 10)")
  end
end
