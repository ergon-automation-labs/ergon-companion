defmodule BotArmyRuntime.Repo.Migrations.CreateMemoryEntries do
  @moduledoc """
  TEMPLATE MIGRATION — do not run from bot_army_runtime.

  Each bot that uses `BotArmy.Memory` must copy this migration into its own
  `priv/repo/migrations/` directory, renaming the module to match its namespace:

      defmodule BotArmySynapse.Repo.Migrations.CreateMemoryEntries do
        # ... same content ...
      end

  Then run `mix ecto.migrate` in that bot.
  """

  use Ecto.Migration

  def change do
    create table(:memory_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scope, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:user_id, :string)
      add(:source, :string)
      add(:kind, :string, null: false, default: "thought")
      add(:payload, :jsonb, null: false, default: "{}")
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:memory_entries, [:scope]))
    create(index(:memory_entries, [:tenant_id]))
    create(index(:memory_entries, [:kind]))
    create(index(:memory_entries, [:scope, :tenant_id, :kind, :recorded_at]))
  end
end
