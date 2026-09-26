Application.ensure_all_started(:mox)

ExUnit.configure(exclude: [:integration, :load, :nats_live])

ExUnit.start()

Code.require_file("support/postgres_helper.ex", __DIR__)

# Define Mox mocks for external dependencies
Mox.defmock(HTTPClientMock, for: BotArmyCompanion.HTTPClient)
Mox.defmock(ReflectionAnswerLlmMock, for: BotArmyCompanion.ReflectionAnswer.Llm)

# Try to set up database sandbox, but don't fail if database is unavailable
try do
  Ecto.Adapters.SQL.Sandbox.mode(BotArmyCompanion.Repo, :manual)
rescue
  _ -> :ok
end
