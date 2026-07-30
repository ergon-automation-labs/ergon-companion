# BotArmyLearning Migration: Learning Outcomes (Part 1 of 3)
#
# Purpose: Record bot decisions and their actual outcomes for FSRS-5 spaced repetition learning.
# This table tracks verification against reality for each decision a bot makes.
#
# Shared Library Pattern:
# - This migration lives in bot_army_learning but needs to run in CONSUMING BOT repos
# - BotArmyLearning is a path dependency (not a separate service with its own DB)
# - Each bot that uses learning features must apply these 3 migrations to its own database
#
# How to Apply to Another Repo (e.g., bot_army_gtd):
#
# 1. Copy all 3 migration files from bot_army_learning/priv/repo/migrations/ to your bot's
#    priv/repo/migrations/ directory
#
# 2. Rename each with a UNIQUE version number for your bot (avoid duplicates):
#    - If your latest migration is 20260430000005, use 20260501000001, 000002, 000003
#    - Keep the names the same (_create_learning_outcomes, _create_learning_prompt_variants, etc)
#    - Example: 20260501000001_create_learning_outcomes.exs
#
# 3. Update module names to use your repo:
#    - Change: BotArmyLearning.Repo.Migrations.CreateLearningOutcomes
#    - To:     BotArmyGtd.Repo.Migrations.CreateLearningOutcomes
#
# 4. Add runtime config in your config/runtime.exs:
#    config :bot_army_learning, ecto_repos: [BotArmyLearning.Repo]
#    config :bot_army_learning, BotArmyLearning.Repo,
#      database: System.get_env("DATABASE_NAME") || "bot_army_gtd",
#      hostname: System.get_env("DATABASE_HOST") || "localhost",
#      port: String.to_integer(System.get_env("DATABASE_PORT") || "5432"),
#      username: System.get_env("DATABASE_USER") || "postgres",
#      password: System.get_env("DATABASE_PASSWORD") || "postgres",
#      pool_size: 3
#
# 5. Create a Release module if your bot doesn't have one (see Release.ex pattern in bot_army_dispatcher)
#
# Schema Details: learning_outcomes
# - id: UUID, primary key, uniquely identifies this decision outcome pair
# - item_id: The thing being decided on (e.g., "task_123", "proposal_456")
# - category: Type of decision (e.g., "retry_confidence", "optimization_rank")
# - decision: The bot's decision value (e.g., "extend_retry", "apply_optimization")
# - actual_result: What actually happened (e.g., "fix_succeeded", "fix_failed")
# - was_correct: Boolean - did the decision lead to the expected outcome?
# - recorded_at: When this outcome was verified (may be later than decision time)
# - inserted_at: When this record was created
#
# Indexes:
# - (category, item_id): Query outcomes for a specific decision type on a specific item
# - (recorded_at, category): Time-range queries for recent outcomes of a decision type

defmodule BotArmyLearning.Repo.Migrations.CreateLearningOutcomes do
  use Ecto.Migration

  def change do
    create table(:learning_outcomes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:item_id, :string, null: false)
      add(:category, :string, null: false)
      add(:decision, :string, null: false)
      add(:actual_result, :string, null: false)
      add(:was_correct, :boolean, null: false)
      add(:recorded_at, :utc_datetime, null: false)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(index(:learning_outcomes, [:category, :item_id]))
    create(index(:learning_outcomes, [:recorded_at, :category]))
  end
end
