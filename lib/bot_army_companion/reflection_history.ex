defmodule BotArmyCompanion.ReflectionHistory do
  @moduledoc """
  Parse and summarize prior reflections to extract themes and blockers.

  Helps Companion understand what it's been thinking about across multiple
  reflection cycles, so it can notice patterns and avoid repetitive loops.
  """

  require Logger
  alias BotArmyCompanion.ParaClient

  @doc """
  Fetch and summarize the last N reflections for a given angle.

  Returns {:ok, summary} with keys:
  - :count — number of reflections fetched
  - :oldest_date — earliest reflection date
  - :newest_date — latest reflection date
  - :themes — list of identified themes
  - :blockers — list of identified blockers
  - :context — formatted text summary for prompt injection
  """
  def summarize_prior_reflections(angle, limit \\ 5) do
    Logger.debug("ReflectionHistory.summarize_prior_reflections: angle=#{angle}, limit=#{limit}")

    # Fetch prior reflections from PARA
    case fetch_reflections_for_angle(angle) do
      {:ok, [_ | _] = reflections} ->
        Logger.debug(
          "ReflectionHistory: Found #{length(reflections)} prior reflections for angle #{angle}"
        )

        # Sort by date descending (newest first) and take limit
        recent = reflections |> Enum.sort_by(fn r -> r.date end, :desc) |> Enum.take(limit)

        # Extract themes and blockers
        themes = extract_themes(recent)
        blockers = extract_blockers(recent)
        dates = Enum.map(recent, & &1.date)
        oldest_date = List.last(dates)
        newest_date = List.first(dates)

        # Build context for injection into prompt
        context =
          build_context_summary(themes, blockers, oldest_date, newest_date, length(recent))

        {:ok,
         %{
           count: length(recent),
           oldest_date: oldest_date,
           newest_date: newest_date,
           themes: themes,
           blockers: blockers,
           context: context
         }}

      {:ok, []} ->
        Logger.debug("ReflectionHistory: No prior reflections found for angle #{angle}")

        {:ok,
         %{
           count: 0,
           oldest_date: nil,
           newest_date: nil,
           themes: [],
           blockers: [],
           context: ""
         }}

      error ->
        Logger.error("ReflectionHistory: Failed to fetch prior reflections: #{inspect(error)}")

        # Graceful degradation: return empty summary instead of failing
        {:ok,
         %{
           count: 0,
           oldest_date: nil,
           newest_date: nil,
           themes: [],
           blockers: [],
           context: ""
         }}
    end
  end

  # Fetch reflection files for a specific angle from PARA
  defp fetch_reflections_for_angle(angle) do
    path = "areas/companion/observations"

    case ParaClient.list_directory(path, false, 5_000) do
      {:ok, entries} ->
        reflections =
          entries
          |> Enum.filter(&String.match?(&1, ~r/angle-#{angle}/))
          |> Enum.map(&parse_reflection_filename/1)
          |> Enum.filter(&(&1 != nil))

        Logger.debug("ReflectionHistory: Parsed #{length(reflections)} reflection files")
        {:ok, reflections}

      error ->
        error
    end
  end

  # Parse a reflection filename like "2026-08-24-angle-3.md"
  defp parse_reflection_filename(filename) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2})-angle-(\d+)/, filename) do
      [_full, date, angle] ->
        %{
          filename: filename,
          date: date,
          angle: String.to_integer(angle)
        }

      _ ->
        nil
    end
  end

  # Extract recurring themes from recent reflections
  # (In a real implementation, this could use NLP or keyword extraction)
  defp extract_themes(reflections) do
    # For now, return generic theme hints based on reflection count
    # A real implementation could parse content or use an LLM
    case length(reflections) do
      0 -> []
      1 -> ["New angle being explored"]
      2 -> ["Pattern emerging across 2 cycles"]
      n when n >= 3 -> ["Recurring focus over #{n} cycles", "Consistent attention"]
      _ -> []
    end
  end

  # Extract blockers from recent reflections
  defp extract_blockers(_reflections) do
    # A real implementation could parse content or use an LLM to identify blockers
    # For now, return empty to avoid false positives
    []
  end

  # Build a natural language summary for prompt injection
  defp build_context_summary(themes, blockers, oldest_date, newest_date, count) do
    case count do
      0 ->
        ""

      1 ->
        "This is the first reflection on this angle."

      2 ->
        "You've reflected on this angle twice: #{oldest_date} and #{newest_date}."

      n ->
        base =
          "You've been thinking about this for #{n} cycles (#{oldest_date} to #{newest_date})"

        themes_text =
          case themes do
            [] -> ""
            t -> ". Patterns noticed: #{Enum.join(t, ", ")}."
          end

        blockers_text =
          case blockers do
            [] -> ""
            b -> " Blockers: #{Enum.join(b, ", ")}."
          end

        base <> themes_text <> blockers_text
    end
  end
end
