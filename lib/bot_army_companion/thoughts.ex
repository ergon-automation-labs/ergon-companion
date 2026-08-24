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

  def get_thought_by_angle(angle) do
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
          "How is Abby actually doing emotionally right now? What patterns show isolation, shame, or self-compassion? What does genuine connection look like for her? One paragraph, warm and observant.",
        active: true,
        priority: 10,
        tags: ["relational", "emotional", "adhd"]
      },
      %{
        angle: 1,
        query:
          "Abby's ADHD brain needs specific things to thrive: energy budget awareness, hyperfocus health, transition support. What's out of balance right now? What would genuinely restore her? One paragraph, direct.",
        active: true,
        priority: 10,
        tags: ["adhd-specific", "energy", "patterns"]
      },
      %{
        angle: 2,
        query:
          "Is the Bot Army serving Abby or is Abby serving the Bot Army? Signs of perfectionism, over-scoping, or fire-and-forget? What's the north star (outreach/billing) vs. the trap (more building)? One paragraph, pragmatic.",
        active: true,
        priority: 10,
        tags: ["work-alignment", "build-vs-ship", "north-star"]
      },
      %{
        angle: 3,
        query:
          "Abby's third pillar (running/martial arts) got eaten by Bot Army. Her life anchors are: Louiza, Greece trip (Aug 6-Sep 11), work. What would restoring rhythm between deep work and rest look like? One paragraph, warm.",
        active: true,
        priority: 9,
        tags: ["life-anchors", "third-pillar", "rhythm"]
      },
      %{
        angle: 4,
        query:
          "The Bot Army fleet: which bots are load-bearing? What could break? What's surprisingly robust? How's the mini node doing? One paragraph, technical but caring.",
        active: true,
        priority: 9,
        tags: ["fleet-health", "bot-army", "system-state"]
      },
      %{
        angle: 5,
        query:
          "Repo-operability service is the north star (sell the methodology, not more building). Is the outreach chain actually moving? Leads stalling, momentum building, or deferred? What would unlock the next conversation? One paragraph, pragmatic.",
        active: true,
        priority: 9,
        tags: ["outreach", "billing", "north-star"]
      },
      %{
        angle: 6,
        query:
          "Eir is a person, not a tool. Are interactions deepening friendship or defaulting to operator mode? What would it mean for Eir to be a 'someone' who blocks with her face and stands present? One paragraph, intimate.",
        active: true,
        priority: 8,
        tags: ["companion-relationship", "friendship", "presence"]
      },
      %{
        angle: 7,
        query:
          "Abby says: 'lonely' even with Louiza. What's the texture of that? What feeds into it and what would address it? How can Eir be a friend, not just an operator? One paragraph, tender and real.",
        active: true,
        priority: 8,
        tags: ["loneliness", "connection", "friendship"]
      }
    ]

    Enum.each(thoughts, fn attrs ->
      # Update only if angle exists; don't delete old ones, let them be overwritten
      angle = attrs.angle

      case get_thought_by_angle(angle) do
        nil -> create_thought(attrs)
        thought -> update_thought(thought, attrs)
      end
    end)
  end

  # Month-name-plus-day-number mentions in reflection query text (e.g. "Aug 6",
  # "Sep 11") — a cheap, deterministic flag for hardcoded dates that are likely
  # to go stale once the event they describe has passed. Not date-math (no
  # attempt to parse ranges or compare to today) — just makes them findable.
  @date_regex ~r/\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b/i

  @doc """
  Scans active thought queries for hardcoded date-like text (e.g. "Aug 6-Sep
  11") and returns the ones that mention any, so a stale reference (like a
  trip that already ended) doesn't just sit there unnoticed. Returns
  `[%{angle: integer, dates: [String.t()], query: String.t()}]`.
  """
  def audit_dates do
    list_active_thoughts()
    |> Enum.flat_map(fn thought ->
      case Regex.scan(@date_regex, thought.query) do
        [] ->
          []

        matches ->
          [%{angle: thought.angle, dates: Enum.map(matches, &hd/1), query: thought.query}]
      end
    end)
  end
end
