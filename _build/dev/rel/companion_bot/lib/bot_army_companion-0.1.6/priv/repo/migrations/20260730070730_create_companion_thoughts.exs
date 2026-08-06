defmodule BotArmyCompanion.Repo.Migrations.CreateCompanionThoughts do
  use Ecto.Migration

  def change do
    create table(:companion_thoughts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:angle, :integer,
        null: false,
        comment: "0=personal, 1=bot_army, 2=outreach, 3=life_balance"
      )

      add(:query, :text, null: false, comment: "The LLM prompt for this reflection angle")
      add(:active, :boolean, default: true, null: false)
      add(:priority, :integer, default: 0, comment: "Higher priority selected first")
      add(:tags, {:array, :string}, default: [], null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:companion_thoughts, [:angle]))
  end
end
