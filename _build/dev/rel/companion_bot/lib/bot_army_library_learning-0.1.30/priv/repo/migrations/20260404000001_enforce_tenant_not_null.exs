defmodule BotArmyLearning.Repo.Migrations.EnforceTenantNotNull do
  use Ecto.Migration

  def up do
    for table <- [:learning_domains, :learning_decks, :learning_cards, :learning_sessions, :learning_reviews, :learning_snoozes] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id SET NOT NULL")
    end
  end

  def down do
    for table <- [:learning_domains, :learning_decks, :learning_cards, :learning_sessions, :learning_reviews, :learning_snoozes] do
      execute("ALTER TABLE #{table} ALTER COLUMN tenant_id DROP NOT NULL")
    end
  end
end
