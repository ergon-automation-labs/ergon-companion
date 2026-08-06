import Config

# Runtime configuration — evaluated when the release boots, not at compile time.
# config/prod.exs only runs at `mix release` build time, so DATABASE_URL etc.
# set by Salt/launchd on the deploy target were never actually read.

if config_env() == :prod do
  config :bot_army_companion, BotArmyCompanion.Repo,
    database:
      System.get_env("BOT_ARMY_COMPANION_BOT_DB_NAME") || System.get_env("DATABASE_NAME") ||
        "ergon_companion",
    hostname:
      System.get_env("BOT_ARMY_COMPANION_BOT_DB_HOST") || System.get_env("DATABASE_HOST") ||
        "localhost",
    port:
      String.to_integer(
        System.get_env("BOT_ARMY_COMPANION_BOT_DB_PORT") || System.get_env("DATABASE_PORT") ||
          "30006"
      ),
    username:
      System.get_env("BOT_ARMY_COMPANION_BOT_DB_USER") || System.get_env("DATABASE_USER") ||
        "postgres",
    password:
      System.get_env("BOT_ARMY_COMPANION_BOT_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD") ||
        "postgres",
    pool_size: String.to_integer(System.get_env("POSTGRES_POOL_SIZE") || "10"),
    ssl: System.get_env("DATABASE_SSL") == "true",
    socket_options:
      if(System.get_env("DATABASE_SOCKET_TIMEOUT"),
        do: [connect_timeout: String.to_integer(System.get_env("DATABASE_SOCKET_TIMEOUT"))],
        else: []
      )

  config :logger, level: String.to_atom(System.get_env("LOG_LEVEL") || "info")
end
