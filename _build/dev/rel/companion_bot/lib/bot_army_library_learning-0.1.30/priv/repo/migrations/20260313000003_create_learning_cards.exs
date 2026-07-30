defmodule BotArmyLearning.Repo.Migrations.CreateLearningCards do
  use Ecto.Migration

  def change do
    create table(:learning_cards, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :deck_id, references(:learning_decks, type: :binary_id), null: false
      add :front, :text, null: false
      add :back, :text, null: false
      add :type, :string, null: false, default: "recall"
      add :tags, {:array, :string}, default: []

      # FSRS fields
      add :stability, :float, default: 2.5
      add :difficulty, :float, default: 5.0
      add :due_at, :date, null: false

      timestamps()
    end

    create index(:learning_cards, [:deck_id])
    create index(:learning_cards, [:due_at])
  end
end
