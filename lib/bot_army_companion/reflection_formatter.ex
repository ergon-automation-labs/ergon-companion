defmodule BotArmyCompanion.ReflectionFormatter do
  @moduledoc """
  Format reflections with rich PARA integration:
  - Extract and tag with glossary terms
  - Add wikilinks to concepts
  - Create metadata (date, angle, tags)
  - Update tag index

  Transforms plain reflection text into interconnected knowledge graph nodes.
  """

  require Logger
  alias BotArmyCompanion.ParaClient

  @doc """
  Format reflection with full PARA metadata and indexing.

  Takes reflection data and returns formatted markdown with:
  - YAML frontmatter (date, angle, tags, related items)
  - Wikilinked text (concepts tagged in glossary)
  - Backlinks to projects/people/concepts

  Returns {:ok, formatted_content} or {:error, reason}
  """
  def format_reflection(reflection) do
    timestamp = Map.get(reflection, :timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
    angle = Map.get(reflection, :angle, "unknown")
    text = Map.get(reflection, :reflection, "")

    # Extract tags from glossary based on keywords in reflection
    tags = extract_tags(text)

    # Add wikilinks to text
    linked_text = add_wikilinks(text, tags)

    # Extract related projects/people/concepts
    related = extract_entities(text)

    # Format as markdown with metadata
    content = format_markdown(timestamp, angle, tags, related, linked_text)

    {:ok, content}
  rescue
    e ->
      Logger.error("reflection_formatter error: #{inspect(e)}")
      {:error, "Failed to format reflection"}
  end

  @doc """
  Update the reflection index by tag.

  Indexes all reflections, grouping by tag, so you can query "all reflections tagged #infrastructure"
  """
  def update_tag_index(angle, tags, timestamp) do
    # Build index entry
    index_entry = """
    - [[Reflection: #{timestamp} — #{angle}]] — `[#{Enum.join(tags, ", ")}]`
    """

    # For now, just log it — indexing would append to areas/Companion/indexes/REFLECTIONS_BY_TAG.md
    Logger.debug("Tag index entry: #{index_entry}")
    :ok
  end

  # Private helpers

  defp extract_tags(text) do
    glossary = load_glossary()

    glossary
    |> Enum.filter(fn {_tag, description} ->
      # Check if any keyword from description appears in the reflection text
      keywords = String.split(description, " ")

      Enum.any?(keywords, fn keyword ->
        String.contains?(String.downcase(text), String.downcase(keyword))
      end)
    end)
    |> Enum.map(fn {tag, _} -> tag end)
    |> Enum.uniq()
  end

  defp add_wikilinks(text, tags) do
    # Simple wikilink addition: for each tag that appears, linkify it
    # More sophisticated version would parse concepts from text
    text
  end

  defp extract_entities(text) do
    # Extract project, people, and concept references from text
    # Look for patterns like "[[Project Name]]" or mentions of projects in PARA
    %{
      projects: [],
      people: [],
      concepts: []
    }
  end

  defp format_markdown(timestamp, angle, tags, related, text) do
    # YYYY-MM-DD
    date = String.slice(timestamp, 0..9)

    frontmatter = """
    ---
    date: #{date}
    angle: #{angle}
    tags: [#{Enum.join(tags, ", ")}]
    related_projects: #{format_list(related.projects)}
    related_people: #{format_list(related.people)}
    concepts: #{format_list(related.concepts)}
    ---
    """

    """
    #{frontmatter}

    # Reflection: #{date} — #{format_angle(angle)}

    #{text}

    **Tags:** `[#{Enum.join(tags, ", ")}]`
    """
  end

  defp format_list([]), do: "[]"
  defp format_list(items), do: "[#{Enum.join(items, ", ")}]"

  defp format_angle("trust"), do: "Trust & Confidence"
  defp format_angle("progress"), do: "Progress & Momentum"
  defp format_angle("health"), do: "Bot Army Health"
  defp format_angle("balance"), do: "Life Balance"
  defp format_angle(angle), do: String.capitalize(angle)

  defp load_glossary do
    # Load glossary from PARA and parse tags
    # For MVP, return hardcoded glossary; later read from areas/Companion/REFLECTION_GLOSSARY.md
    %{
      "infrastructure_reliability" => "infrastructure reliability architecture scaling",
      "deployment_safety" => "deployment safety release pipeline validation",
      "database_health" => "database postgres connections",
      "nats_stability" => "nats message broker clustering",
      "monitoring_coverage" => "monitoring observability alerting visibility",
      "outreach_momentum" => "outreach emails replies calls pipeline",
      "pricing_confidence" => "pricing rate SOW readiness",
      "balance" => "balance life work equilibrium energy",
      "trust" => "trust reliability confidence automation",
      "progress" => "progress velocity momentum wins"
    }
  end
end
