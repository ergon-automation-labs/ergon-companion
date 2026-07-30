defmodule BotArmyLearning.Repo.Migrations.CreateLearningSnoozes do
  use Ecto.Migration

  def change do
    create table(:learning_snoozes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :card_id, references(:learning_cards, type: :binary_id), null: false
      add :snoozed_until, :utc_datetime, null: false
      add :reason, :string

      timestamps()
    end

    create index(:learning_snoozes, [:card_id])
    create index(:learning_snoozes, [:snoozed_until])
  end
end
