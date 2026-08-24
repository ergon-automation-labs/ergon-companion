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

        # Read file content for the most recent reflection to check whether
        # Abby replied to it — that's what actually makes this a conversation
        # rather than a monologue.
        latest_reply = fetch_latest_reply(recent)

        # Build context for injection into prompt
        context =
          build_context_summary(
            themes,
            blockers,
            oldest_date,
            newest_date,
            length(recent),
            latest_reply
          )

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

  # Read the most recent reflection's file content and pull out the latest
  # "## Abby's reply — ..." section, if any. This is the one piece of real
  # content this module reads — everything else here is filename metadata.
  defp fetch_latest_reply([]), do: nil

  defp fetch_latest_reply([%{filename: filename} | _rest]) do
    path = "areas/companion/observations/#{filename}"

    case ParaClient.read_file(path) do
      {:ok, content} -> extract_latest_reply_section(content)
      _ -> nil
    end
  end

  defp extract_latest_reply_section(content) do
    matches = Regex.scan(~r/## Abby's reply.*?\n\n(.*?)\n\n/s, content)

    case List.last(matches) do
      [_full, reply_text] ->
        reply_text |> String.trim()

      _ ->
        nil
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
  defp build_context_summary(themes, blockers, oldest_date, newest_date, count, latest_reply) do
    base_text(count, oldest_date, newest_date) <>
      themes_text(count, themes) <>
      blockers_text(count, blockers) <>
      reply_context_text(latest_reply)
  end

  defp base_text(0, _oldest_date, _newest_date), do: ""
  defp base_text(1, _oldest_date, _newest_date), do: "This is the first reflection on this angle."

  defp base_text(2, oldest_date, newest_date),
    do: "You've reflected on this angle twice: #{oldest_date} and #{newest_date}."

  defp base_text(n, oldest_date, newest_date),
    do: "You've been thinking about this for #{n} cycles (#{oldest_date} to #{newest_date})"

  defp themes_text(count, _themes) when count < 3, do: ""
  defp themes_text(_count, []), do: ""
  defp themes_text(_count, themes), do: ". Patterns noticed: #{Enum.join(themes, ", ")}."

  defp blockers_text(count, _blockers) when count < 3, do: ""
  defp blockers_text(_count, []), do: ""
  defp blockers_text(_count, blockers), do: " Blockers: #{Enum.join(blockers, ", ")}."

  defp reply_context_text(nil), do: ""

  defp reply_context_text(reply) do
    " Abby replied to your last reflection on this: \"#{truncate(reply, 500)}\" — respond to that directly, don't just repeat yourself."
  end

  defp truncate(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len) <> "…"
  end

  defp truncate(text, _max_len), do: text
end
