import Config

config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :task_id]

config :logger_json, :backend, formatter: LoggerJSON.Formatters.DatadogLogger

config :bot_army_companion, BotArmyCompanion.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  priv: "priv/repo"
