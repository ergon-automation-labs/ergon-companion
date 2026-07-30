defmodule BotArmyLearning.Repo.Migrations.CreateLearningDecks do
  use Ecto.Migration

  def change do
    create table(:learning_decks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :domain_id, references(:learning_domains, type: :binary_id), null: false
      add :description, :text
      add :card_count, :integer, default: 0

      timestamps()
    end

    create index(:learning_decks, [:domain_id])
  end
end
