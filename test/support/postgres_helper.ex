defmodule BotArmyCompanion.Test.PostgresHelper do
  @moduledoc """
  Helpers for the `:integration` tests that need a live Postgres.

  Those tests are excluded from the default suite (`test_helper.exs`) and, when
  run, point at a dedicated *test* database — see `config/test.exs`. They must
  never be aimed at the companion's production database.
  """

  alias Ecto.Adapters.SQL

  @doc """
  Wipes the `public` schema of an already-started repo, so a migration test
  begins from a clean database.

  `DROP SCHEMA public CASCADE` is the Postgres equivalent of deleting a SQLite
  file, and it keeps the assertions honest ("the table exists because our
  migration created it"). It needs ownership of the test database.
  """
  def reset_schema!(repo) do
    SQL.query!(repo, "DROP SCHEMA public CASCADE")
    SQL.query!(repo, "CREATE SCHEMA public")
    SQL.query!(repo, "GRANT ALL ON SCHEMA public TO public")

    :ok
  end
end
