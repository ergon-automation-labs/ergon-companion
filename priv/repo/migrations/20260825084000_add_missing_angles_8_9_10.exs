defmodule BotArmyCompanion.Repo.Migrations.AddMissingAngles8_9_10 do
  use Ecto.Migration

  def up do
    now = DateTime.utc_now()

    rows = [
      %{
        id: Ecto.UUID.string_to_binary(Ecto.UUID.generate()),
        angle: 8,
        query:
          "What's a recent win — a fix shipped, a fast diagnosis, an outreach reply, anything that actually happened — that hasn't been acknowledged? Celebrate the action taken, not the outcome. One paragraph, warm.",
        active: true,
        priority: 8,
        tags: ["wins", "celebration", "adhd"],
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.string_to_binary(Ecto.UUID.generate()),
        angle: 9,
        query:
          "Is Abby's trust in the Bot Army system growing or eroding right now? Is she fighting the same fire repeatedly, or genuinely making progress? What would rebuild confidence if it's slipping? One paragraph, honest.",
        active: true,
        priority: 8,
        tags: ["trust", "reliability", "system-state"],
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.string_to_binary(Ecto.UUID.generate()),
        angle: 10,
        query:
          "When did Abby last fully disconnect — not rest-shaped busywork, actual stopping? Is she protecting recovery time or pretending to? One paragraph, direct but kind.",
        active: true,
        priority: 8,
        tags: ["rest", "boundaries", "adhd"],
        inserted_at: now,
        updated_at: now
      }
    ]

    repo().insert_all("companion_thoughts", rows)
  end

  def down do
    execute("DELETE FROM companion_thoughts WHERE angle IN (8, 9, 10)")
  end
end
