import Config

config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :task_id]

config :logger_json, :backend, formatter: LoggerJSON.Formatters.DatadogLogger

# The companion answers the reflections she writes. The uncensored lane is a
# local model and is slow (measured ~45s for thirty tokens), so the answer is a
# background job and the row carries its state while it runs. `mode: :inline`
# in test runs it in the calling process, against the mock — nothing here should
# be able to reach a real model during `mix test`.
config :bot_army_companion, :reflection_answer,
  enabled: true,
  mode: :async,
  model_type: "uncensored",
  lane: "interactive",
  max_tokens: 900,
  budget_ms: 300_000

config :bot_army_companion, ecto_repos: [BotArmyCompanion.Repo]

config :bot_army_companion, BotArmyCompanion.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  priv: "priv/repo"

# The test suite has a config file of its own (`config/test.exs`): a hermetic
# NATS port and a *test* database, so a `mix test` can neither join the live
# broker nor touch the companion's production database.
#
# The import is deliberately narrow rather than `import_config "#{config_env()}.exs"`.
# This bot's `config/prod.exs` has never been loaded — production wiring lives in
# `config/runtime.exs`, which re-sets every field — and there is no `dev.exs` at
# all. A blanket import would newly apply a compile-time production config to a
# live bot (and crash `mix compile` in dev) purely because the test suite wanted
# a pin. If production ever does move into `prod.exs`, widen this on purpose.
if config_env() == :test, do: import_config("test.exs")
