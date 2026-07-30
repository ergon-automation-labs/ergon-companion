defmodule BotArmyLearning.Repo.Migrations.CreateLearningReviews do
  use Ecto.Migration

  def change do
    create table(:learning_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :card_id, references(:learning_cards, type: :binary_id), null: false
      add :session_id, references(:learning_sessions, type: :binary_id), null: false
      add :grade, :integer, null: false
      add :review_duration_ms, :integer

      timestamps()
    end

    create index(:learning_reviews, [:card_id])
    create index(:learning_reviews, [:session_id])
  end
end
