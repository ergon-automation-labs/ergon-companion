defmodule BotArmyCompanion.Release do
  @moduledoc """
  Release tasks for the Companion bot.

  Migrations and seed data are run via the shared BotArmyLibraryRuntime.Ecto.MigrationRunner:

      /path/to/companion_bot/bin/companion_bot eval 'BotArmyCompanion.Release.migrate()'

  This calls:
  1. All Ecto migrations (from runtime and companion app)
  2. seed_default_thoughts/0 to populate companion_thoughts table

  Called from Salt during bot deployment, before the bot starts.
  """

  alias BotArmyLibraryRuntime.Ecto.MigrationRunner

  @app :bot_army_companion

  def migrate do
    MigrationRunner.run(
      repo_module: BotArmyCompanion.Repo,
      app_module: @app
    )

    # Seed default companion_thoughts after migrations complete.
    # This ensures both schema changes and seed data run through the same
    # hard-gated path (deployment blocks if either fails) rather than the
    # optional Salt cmd.run step that only warns and continues.
    seed()
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
