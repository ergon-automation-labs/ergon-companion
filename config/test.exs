import Config

# A test run must never join a live broker. Two independent resolution paths
# decide the port, so both need pinning:
#
#   * the registry / conv manager read NATS_PORT from the environment, which
#     means a stray `export NATS_PORT=4222` in a developer shell put the whole
#     suite on the *production* bus;
#   * BotArmyLibraryRuntime.NATS.Connection reads
#     `Application.get_env(:bot_army_library_runtime, :nats)[:servers]`, which
#     falls through to the library's dev-broker default (4223) when unset.
#
# 42991 is the fleet's hermetic test port (nothing listens there).
System.put_env("NATS_PORT", "42991")
config :bot_army_library_runtime, :nats, servers: [{"localhost", 42_991}]

# The answer side, hermetically: no broker, no model, no waiting. The seam is a
# Mox mock (defined in test_helper.exs), and `:inline` means a captured
# reflection is answered in the calling process, so a test can assert on the
# stored answer instead of racing a task.
config :bot_army_companion, :reflection_answer,
  enabled: true,
  mode: :inline,
  llm: ReflectionAnswerLlmMock

# The default suite never opens a database connection: every migration/store
# test is tagged :integration and excluded in test_helper.exs. When you do run
# them they go to a *test* database — never the companion's production database
# — and you must name it explicitly if your cluster differs:
#
#   BOT_ARMY_COMPANION_DB_NAME=ergon_companion_test \
#   BOT_ARMY_COMPANION_DB_PORT=30003 mix test --include integration
#
# Defaults point at the direct Postgres port (30003) rather than PgBouncer
# (30006): these tests drop and recreate the schema, and the admin path is the
# one that can do that.
config :bot_army_companion, BotArmyCompanion.Repo,
  database: System.get_env("BOT_ARMY_COMPANION_DB_NAME", "ergon_companion_test"),
  hostname: System.get_env("BOT_ARMY_COMPANION_DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("BOT_ARMY_COMPANION_DB_PORT", "30003")),
  username: System.get_env("BOT_ARMY_COMPANION_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_COMPANION_DB_PASSWORD", "postgres"),
  pool_size: 2
