defmodule BotArmyRuntime.Repo.Migrations.CreateSouls do
  @moduledoc """
  TEMPLATE MIGRATION — do not run from bot_army_runtime.

  bot_army_runtime is a shared library with no database of its own.
  Each bot that uses BotArmy.Soul must copy this migration into its own
  `priv/repo/migrations/` directory, renaming the module to match its namespace:

      defmodule BotArmyGtd.Repo.Migrations.CreateSouls do
        # ... same content ...
      end

  Copy `20260420000002_create_heartbeats.exs` and `20260420000003_create_memory_entries.exs`
  the same way when persisting `system.health` heartbeats or session memory via
  `BotArmy.Heartbeat` / `BotArmy.Memory`.

  Then run `mix ecto.migrate` in that bot.
  """

  use Ecto.Migration

  def change do
    create table(:souls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_id, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:config, :jsonb, null: false, default: "{}")
      add(:version, :integer, null: false, default: 1)
      add(:active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(index(:souls, [:bot_id]))
    create(index(:souls, [:tenant_id]))
    create(index(:souls, [:bot_id, :tenant_id], unique: true, name: :souls_bot_tenant_unique))
  end
end
