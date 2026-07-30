# BotArmyLearning Migration: Learning Optimization Proposals (Part 3 of 3)
#
# Purpose: Track proposed optimizations and their acceptance/rejection status.
# Proposals come from LLM analysis of bot behavior and are accepted or rejected
# by operators or automated gates, then fed back to the learning system.
#
# Shared Library Pattern: See 20260515_create_learning_outcomes.exs for detailed instructions
# on how to apply this migration to other repos.
#
# When Copying:
# - Same version number renaming rules as learning_outcomes
# - Update module name: BotArmyLearning.Repo.Migrations.CreateLearningOptimizationProposals
#                    → BotArmy<YourBot>.Repo.Migrations.CreateLearningOptimizationProposals
#
# Schema Details: learning_optimization_proposals
# - id: UUID, primary key
# - category: Type of optimization (e.g., "retry_threshold", "prompt_improvement")
# - type: Specific proposal type (e.g., "increase_threshold", "use_prompt_v2")
# - current_value: Current setting being changed (numerical or string representation)
# - proposed_value: New value being proposed
# - reason: Explanation from LLM why this change would help (for audit trail)
# - status: "pending", "accepted", "rejected", or "applied"
#   * pending: Awaiting review/decision
#   * accepted: Approved for application
#   * rejected: Declined by operator or gate
#   * applied: Successfully applied and in use
# - proposed_at: When the LLM proposed this optimization
# - reviewed_at: When this was approved/rejected (null if still pending)
# - created_at: When this record was created
#
# Indexes:
# - (category, status): Find pending/accepted proposals for a specific optimization type
# - (status): Query all proposals in a given state (pending, applied, etc.)
#
# Usage Flow:
# 1. LLM analyzes outcomes and proposes optimization → record with status="pending"
# 2. Operator or automated gate reviews and decides → status="accepted" or "rejected"
# 3. If accepted, bot applies change and monitors → status="applied" when verified

defmodule BotArmyLearning.Repo.Migrations.CreateLearningOptimizationProposals do
  use Ecto.Migration

  def change do
    create table(:learning_optimization_proposals, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:category, :string, null: false)
      add(:type, :string, null: false)
      add(:current_value, :float, null: false)
      add(:proposed_value, :float, null: false)
      add(:reason, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:proposed_at, :utc_datetime, null: false)
      add(:reviewed_at, :utc_datetime)
      add(:created_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(index(:learning_optimization_proposals, [:category, :status]))
    create(index(:learning_optimization_proposals, [:status]))
  end
end
