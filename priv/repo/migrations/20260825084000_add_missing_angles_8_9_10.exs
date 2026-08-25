defmodule BotArmyCompanion.Repo.Migrations.AddMissingAngles8_9_10 do
  use Ecto.Migration

  def up do
    execute("""
      INSERT INTO companion_thoughts (id, angle, query, active, priority, tags, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 8, 'What''s a recent win — a fix shipped, a fast diagnosis, an outreach reply, anything that actually happened — that hasn''t been acknowledged? Celebrate the action taken, not the outcome. One paragraph, warm.', true, 8, ARRAY['wins', 'celebration', 'adhd'], now(), now()),
        (gen_random_uuid(), 9, 'Is Abby''s trust in the Bot Army system growing or eroding right now? Is she fighting the same fire repeatedly, or genuinely making progress? What would rebuild confidence if it''s slipping? One paragraph, honest.', true, 8, ARRAY['trust', 'reliability', 'system-state'], now(), now()),
        (gen_random_uuid(), 10, 'When did Abby last fully disconnect — not rest-shaped busywork, actual stopping? Is she protecting recovery time or pretending to? One paragraph, direct but kind.', true, 8, ARRAY['rest', 'boundaries', 'adhd'], now(), now())
      ON CONFLICT (angle) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM companion_thoughts WHERE angle IN (8, 9, 10)")
  end
end
