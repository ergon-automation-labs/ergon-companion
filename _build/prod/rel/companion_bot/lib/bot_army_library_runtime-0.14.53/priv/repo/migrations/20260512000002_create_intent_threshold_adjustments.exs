defmodule BotArmyRuntime.Repo.Migrations.CreateIntentThresholdAdjustments do
  @moduledoc """
  TEMPLATE MIGRATION — do not run from bot_army_runtime.

  bot_army_runtime is a shared library with no database of its own.
  Each bot that uses BotArmy.IntentThresholdAdjustment must copy this migration
  into its own `priv/repo/migrations/` directory, renaming the module to match
  its namespace:

      defmodule BotArmyGtd.Repo.Migrations.CreateIntentThresholdAdjustments do
        # ... same content ...
      end

  Then run `mix ecto.migrate` in that bot.
  """

  use Ecto.Migration

  def change do
    create table(:intent_threshold_adjustments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_name, :string, null: false)
      add(:action, :string, null: false)
      add(:observation_type, :string, null: false)
      add(:original_weight, :float, null: false)
      add(:adjusted_weight, :float, null: false)
      add(:adjustment_reason, :string)
      add(:source, :string, null: false, default: "reflection")

      timestamps(type: :utc_datetime)
    end

    create(index(:intent_threshold_adjustments, [:bot_name]))
    create(index(:intent_threshold_adjustments, [:bot_name, :action]))
    create(index(:intent_threshold_adjustments, [:bot_name, :action, :observation_type]))
  end
end
