defmodule BotArmyCompanion.Thoughts do
  @moduledoc """
  Context for managing companion thoughts (reflection prompts).
  """

  import Ecto.Query
  alias BotArmyCompanion.Repo
  alias BotArmyCompanion.CompanionThought

  def list_active_thoughts do
    Repo.all(
      from(t in CompanionThought,
        where: t.active == true,
        order_by: [desc: t.priority, asc: t.angle]
      )
    )
  end

  def get_thought_by_angle(angle) when is_integer(angle) and angle >= 0 and angle <= 3 do
    Repo.get_by(CompanionThought, angle: angle, active: true)
  end

  def get_random_active_thought do
    case list_active_thoughts() do
      [] -> :error
      thoughts -> {:ok, Enum.random(thoughts)}
    end
  end

  def create_thought(attrs) do
    %CompanionThought{}
    |> CompanionThought.changeset(attrs)
    |> Repo.insert()
  end

  def update_thought(%CompanionThought{} = thought, attrs) do
    thought
    |> CompanionThought.changeset(attrs)
    |> Repo.update()
  end

  def delete_thought(%CompanionThought{} = thought) do
    Repo.delete(thought)
  end

  def deactivate_thought(%CompanionThought{} = thought) do
    update_thought(thought, %{active: false})
  end

  def seed_default_thoughts do
    thoughts = [
      %{
        angle: 0,
        query:
          "Abby is in Greece (Aug 6 - Sep 11). Given her ADHD brain, sometimes loneliness, third pillar (running/martial arts) displaced by Bot Army - what should Eir notice or hold while she's away? One paragraph, warm and present.",
        active: true,
        priority: 10,
        tags: ["personal", "greece", "adhd"]
      },
      %{
        angle: 1,
        query:
          "While Abby's in Greece, the Bot Army fleet keeps running. What's the state of the system? Which bots matter most? What could break? What's surprisingly robust? One paragraph, technical but human.",
        active: true,
        priority: 10,
        tags: ["bot-army", "fleet", "health"]
      },
      %{
        angle: 2,
        query:
          "Abby's selling the repo-operability service. While she's away in Greece, what momentum matters? Are leads stalling or moving? What would unlock the next conversation? One paragraph, pragmatic focus.",
        active: true,
        priority: 10,
        tags: ["outreach", "billing", "sales"]
      },
      %{
        angle: 3,
        query:
          "Abby's third pillar (running/martial arts) got eaten by Bot Army. Greece is a chance to remember who she is beyond the work. What would it take to actually prioritize her body/movement? One paragraph, direct and warm.",
        active: true,
        priority: 10,
        tags: ["life-balance", "third-pillar", "health"]
      }
    ]

    Enum.each(thoughts, fn attrs ->
      case get_thought_by_angle(attrs.angle) do
        nil -> create_thought(attrs)
        thought -> update_thought(thought, attrs)
      end
    end)
  end
end
