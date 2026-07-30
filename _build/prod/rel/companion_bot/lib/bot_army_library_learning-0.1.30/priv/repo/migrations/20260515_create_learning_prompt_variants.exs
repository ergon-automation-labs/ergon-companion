# BotArmyLearning Migration: Learning Prompt Variants (Part 2 of 3)
#
# Purpose: Store prompt variations tested for different task types, with their performance scores.
# Used by the LLM optimizer to find the highest-performing prompt for each task type.
#
# Shared Library Pattern: See 20260515_create_learning_outcomes.exs for detailed instructions
# on how to apply this migration to other repos.
#
# When Copying:
# - Same version number renaming rules as learning_outcomes
# - Update module name: BotArmyLearning.Repo.Migrations.CreateLearningPromptVariants
#                    → BotArmy<YourBot>.Repo.Migrations.CreateLearningPromptVariants
#
# Schema Details: learning_prompt_variants
# - id: UUID, primary key
# - task_type: Category of task (e.g., "decompose_task", "validate_solution")
# - prompt_hash: SHA256 hash of prompt_text (for deduplication, fast lookup)
# - prompt_text: Full prompt text being tested
# - total_score: Cumulative effectiveness score (higher = better)
# - uses: How many times this prompt has been evaluated
# - last_updated_at: When this prompt's score was last updated
# - created_at: When this variant was first recorded
#
# Unique Constraint:
# - (task_type, prompt_hash): Only one version of a prompt per task type
#   (prevents storing identical prompts multiple times)
#
# Indexes:
# - (task_type, prompt_hash): Unique constraint for deduplication
# - (task_type): Find all prompts for a specific task type for comparison

defmodule BotArmyLearning.Repo.Migrations.CreateLearningPromptVariants do
  use Ecto.Migration

  def change do
    create table(:learning_prompt_variants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:task_type, :string, null: false)
      add(:prompt_hash, :string, null: false)
      add(:prompt_text, :text, null: false)
      add(:total_score, :float, null: false)
      add(:uses, :integer, null: false)
      add(:last_updated_at, :utc_datetime, null: false)
      add(:created_at, :utc_datetime, null: false, default: fragment("NOW()"))
    end

    create(
      unique_index(:learning_prompt_variants, [:task_type, :prompt_hash],
        name: :learning_prompt_variants_task_type_prompt_hash_index
      )
    )

    create(index(:learning_prompt_variants, [:task_type]))
  end
end
