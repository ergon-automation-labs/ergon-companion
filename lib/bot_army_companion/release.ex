defmodule BotArmyCompanion.Release do
  @moduledoc """
  Release tasks for the Companion bot.

  Migrations are run via the shared BotArmyLibraryRuntime.Ecto.MigrationRunner:

      /path/to/companion_bot/bin/companion_bot eval 'BotArmyCompanion.Release.migrate()'

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyLibraryRuntime.Ecto.MigrationRunner

  @app :bot_army_companion

  def migrate do
    MigrationRunner.run(
      repo_module: BotArmyCompanion.Repo,
      app_module: @app
    )
  end
end
