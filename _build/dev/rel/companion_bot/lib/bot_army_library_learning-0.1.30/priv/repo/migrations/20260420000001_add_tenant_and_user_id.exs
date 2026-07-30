defmodule BotArmyLearning.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"

    # Add tenant_id and user_id to learning_domains
    alter table(:learning_domains) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:learning_domains, [:tenant_id]))
    create(index(:learning_domains, [:user_id]))

    execute(
      "UPDATE learning_domains SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )

    # Add tenant_id and user_id to learning_decks
    alter table(:learning_decks) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:learning_decks, [:tenant_id]))
    create(index(:learning_decks, [:user_id]))

    execute(
      "UPDATE learning_decks SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )

    # Add tenant_id and user_id to learning_cards
    alter table(:learning_cards) do
      add(:tenant_id, :uuid, null: true)
      add(:user_id, :uuid, null: true)
    end

    create(index(:learning_cards, [:tenant_id]))
    create(index(:learning_cards, [:user_id]))

    execute(
      "UPDATE learning_cards SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL"
    )
  end

  def down do
    # Drop indexes and columns for learning_domains
    drop(index(:learning_domains, [:tenant_id]))
    drop(index(:learning_domains, [:user_id]))

    alter table(:learning_domains) do
      remove(:tenant_id)
      remove(:user_id)
    end

    # Drop indexes and columns for learning_decks
    drop(index(:learning_decks, [:tenant_id]))
    drop(index(:learning_decks, [:user_id]))

    alter table(:learning_decks) do
      remove(:tenant_id)
      remove(:user_id)
    end

    # Drop indexes and columns for learning_cards
    drop(index(:learning_cards, [:tenant_id]))
    drop(index(:learning_cards, [:user_id]))

    alter table(:learning_cards) do
      remove(:tenant_id)
      remove(:user_id)
    end
  end
end
