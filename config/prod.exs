import Config

config :bot_army_companion, BotArmyCompanion.Repo,
  url: System.get_env("DATABASE_URL") || "postgres://localhost/companion_prod",
  pool_size: String.to_integer(System.get_env("POSTGRES_POOL_SIZE") || "10"),
  ssl: System.get_env("DATABASE_SSL") == "true",
  socket_options:
    if(System.get_env("DATABASE_SOCKET_TIMEOUT"),
      do: [connect_timeout: String.to_integer(System.get_env("DATABASE_SOCKET_TIMEOUT"))],
      else: []
    )

config :logger, level: String.to_atom(System.get_env("LOG_LEVEL") || "info")
