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

  @doc """
  Seeds default companion_thoughts rows.

  `eval` doesn't start the application supervision tree, so
  BotArmyCompanion.Thoughts.seed_default_thoughts/0 can't reach the Repo
  directly — it raises "could not lookup Ecto repo ... not started".
  Ecto.Migrator.with_repo/2 starts just the repo for the duration of the
  function, same as migrate/0 relies on internally.
  """
  def seed do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(BotArmyCompanion.Repo, fn _repo ->
        BotArmyCompanion.Thoughts.seed_default_thoughts()
        {:ok, nil}
      end)

    :ok
  end
end
