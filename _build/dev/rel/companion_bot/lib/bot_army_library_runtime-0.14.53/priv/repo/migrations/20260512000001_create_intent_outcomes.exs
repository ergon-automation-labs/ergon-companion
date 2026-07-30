defmodule BotArmyRuntime.Repo.Migrations.CreateIntentOutcomes do
  @moduledoc """
  TEMPLATE MIGRATION — do not run from bot_army_runtime.

  bot_army_runtime is a shared library with no database of its own.
  Each bot that uses BotArmy.IntentOutcome must copy this migration into its own
  `priv/repo/migrations/` directory, renaming the module to match its namespace:

      defmodule BotArmyGtd.Repo.Migrations.CreateIntentOutcomes do
        # ... same content ...
      end

  Then run `mix ecto.migrate` in that bot.
  """

  use Ecto.Migration

  def change do
    create table(:intent_outcomes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_name, :string, null: false)
      add(:action, :string, null: false)
      add(:intent_id, :string, null: false)
      add(:decision, :string, null: false)
      add(:outcome, :string)
      add(:outcome_metadata, :jsonb, null: false, default: "{}")
      add(:score, :float)
      add(:reason, :string)
      add(:observed_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:intent_outcomes, [:bot_name]))
    create(index(:intent_outcomes, [:action]))
    create(index(:intent_outcomes, [:intent_id]))
    create(index(:intent_outcomes, [:bot_name, :action]))
    create(index(:intent_outcomes, [:bot_name, :action, :observed_at]))
  end
end
