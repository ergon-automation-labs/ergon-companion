defmodule BotArmyCompanion.Repo do
  use Ecto.Repo,
    otp_app: :bot_army_companion,
    adapter: Ecto.Adapters.Postgres
end
