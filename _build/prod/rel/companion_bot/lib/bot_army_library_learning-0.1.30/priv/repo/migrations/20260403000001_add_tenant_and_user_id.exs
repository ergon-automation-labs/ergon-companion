defmodule BotArmy_BOT_NAME.Repo.Migrations.AddTenantAndUserId do
  use Ecto.Migration

  def up do
    default_tenant_id = "00000000-0000-0000-0000-000000000001"
    
    for table <- [_TABLES_] do
      alter table(table) do
        add :tenant_id, :uuid, null: true
        add :user_id, :uuid, null: true
      end
      create index(table, [:tenant_id])
      create index(table, [:user_id])
      execute("UPDATE #{table} SET tenant_id = '#{default_tenant_id}'::uuid WHERE tenant_id IS NULL")
    end
  end

  def down do
    for table <- [_TABLES_] do
      drop index(table, [:tenant_id])
      drop index(table, [:user_id])
      alter table(table) do
        remove :tenant_id
        remove :user_id
      end
    end
  end
end
