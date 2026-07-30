defmodule BotArmyLearning.Repo.Migrations.CreateLearningSessions do
  use Ecto.Migration

  def change do
    create table(:learning_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :deck_id, references(:learning_decks, type: :binary_id), null: false
      add :surface, :string, null: false, default: "terminal"
      add :card_limit, :integer
      add :cards_reviewed, :integer, default: 0
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create index(:learning_sessions, [:deck_id])
    create index(:learning_sessions, [:status])
  end
end
