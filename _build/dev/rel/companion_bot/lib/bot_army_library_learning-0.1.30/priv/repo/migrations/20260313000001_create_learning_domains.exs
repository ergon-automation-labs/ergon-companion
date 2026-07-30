defmodule BotArmyLearning.Repo.Migrations.CreateLearningDomains do
  use Ecto.Migration

  def change do
    create table(:learning_domains, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text

      timestamps()
    end

    create unique_index(:learning_domains, [:name])
  end
end
