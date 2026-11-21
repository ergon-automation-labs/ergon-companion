defmodule BotArmyCompanion.Letters.Grader do
  @moduledoc """
  The check a mission letter passes before it is stored, and the notes it is rewritten from.

  Two kinds of judgment, kept apart on purpose:

    * **Rules** (`rules/4`) are code. A letter breaks one or it does not: markdown, no signature, a
      sentence that steers (`you should`), counting the gap since she last wrote as a fault, no
      closing question, a companion never named, the wrong length. They are the ones her soul states as
      refusals and the letter prompt states as form, so a model cannot talk itself out of them.
    * **The grade** (`grade_prompt/4`, `parse_grade/1`) is a model's read of what code cannot see: does
      the letter stay inside the record (no changed outcome, no invented event), and does it sound like
      her. The standard it judges by is Eir's own soul (character, tone, sample lines), so nobody's
      taste is written into a prompt here.

  `verdict/3` joins them: a letter passes only when both are clean, and otherwise the notes that explain
  what to change are the revision's brief (`revise_user/3`).
  """

  @min_chars 250
  @max_chars 3_000
  @dimensions [:voice, :excitement, :clarity]

  @sentences %{
    markdown: "Write plain prose: no bold, no headings, no lists, no code marks.",
    too_short: "It is too short to be a letter. Tell more of the story: a few short paragraphs.",
    too_long: "It is too long. Keep it to a few short paragraphs.",
    one_block: "It is one block of text. Break it into a few short paragraphs.",
    no_signature: "End the letter with your name on a line of its own, and nothing after it.",
    no_closing_question:
      "Close, just above your name, with one small question about Abby's own day.",
    steering:
      "A sentence tells Abby what she should, must or needs to do. Remove it: no shoulds, no pressure.",
    gap_fault:
      "A sentence counts the time since she last wrote as a fault. Remove it: you are only glad to write."
  }

  @steering ~r/\byou\s+(should|must|need to|have to|ought to|better)\b/i
  @gap ~r/\b(it(?:'s| has)? been (?:a while|so long|too long|ages)|haven't (?:heard|written)|long time no|been quiet)\b/i

  # -- rules -----------------------------------------------------------------------------

  @doc """
  The rules a letter breaks, each once, as `{tag, sentence}`: the sentence is the note an editor would
  write. `[]` means the letter is clean.
  """
  @spec rules(String.t(), map(), String.t(), map()) :: [{atom(), String.t()}]
  def rules(text, debrief, leader_bot_id, soul) when is_binary(text) do
    text = String.trim(text)
    name = soul_name(soul)
    {body, signed?} = split_signature(text, name)

    [
      {markdown?(text), :markdown},
      {String.length(text) < @min_chars, :too_short},
      {String.length(text) > @max_chars, :too_long},
      {length(paragraphs(text)) < 2, :one_block},
      {not signed?, :no_signature},
      {not closes_with_question?(body), :no_closing_question},
      {Regex.match?(@steering, text), :steering},
      {Regex.match?(@gap, text), :gap_fault}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {true, tag} -> {tag, Map.fetch!(@sentences, tag)} end)
    |> add_unnamed(text, debrief, leader_bot_id)
  end

  defp add_unnamed(found, text, debrief, leader_bot_id) do
    missing =
      (debrief["party"] || [])
      |> Enum.reject(&(&1["bot_id"] == leader_bot_id))
      |> Enum.map(&first_name(&1["name"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&Regex.match?(~r/\b#{Regex.escape(&1)}\b/, text))

    case missing do
      [] ->
        found

      names ->
        found ++
          [
            {:companion_unnamed,
             "You never mention #{Enum.join(names, " or ")}, who went with you. Call your companions by name."}
          ]
    end
  end

  defp first_name(name) when is_binary(name) do
    name |> String.replace("\"", "") |> String.split() |> List.first()
  end

  defp first_name(_), do: nil

  defp markdown?(text) do
    Regex.match?(~r/\*\*|__|`/, text) or
      Regex.match?(~r/^\s*(?:\#{1,6}\s|[-*+]\s+\S|\d+\.\s)/m, text)
  end

  defp paragraphs(text),
    do: text |> String.split(~r/\n\s*\n/, trim: true) |> Enum.reject(&(String.trim(&1) == ""))

  # The letter is signed when its last line is her name; what is above it is the body.
  defp split_signature(text, name) do
    lines = String.split(text, "\n")
    last = lines |> List.last() |> to_string() |> String.trim() |> String.replace(~r/[.,!]+$/, "")

    if last == name,
      do: {lines |> Enum.drop(-1) |> Enum.join("\n") |> String.trim(), true},
      else: {text, false}
  end

  defp closes_with_question?(body) do
    case paragraphs(body) do
      [] -> false
      list -> list |> List.last() |> String.contains?("?")
    end
  end

  defp soul_name(soul), do: get_in(soul, ["identity", "name"]) || "Eir"

  # -- the grade -------------------------------------------------------------------------

  @doc """
  The editor's brief and the letter to judge. The soul is the standard of her voice; the record is
  what she may tell; the answer is one JSON object so it can be read by code.
  """
  @spec grade_prompt(map(), String.t(), map(), String.t()) :: {String.t(), String.t()}
  def grade_prompt(soul, letter, debrief, leader_bot_id) do
    system =
      [
        "You are an editor. You read a letter that #{soul_name(soul)} wrote to her pen pal Abby about a game mission, and you judge it. You do not rewrite it.",
        "Who she is, the standard her voice is judged by: #{soul["character"]}",
        if(soul["tone"], do: "Her tone: #{soul["tone"]}."),
        list("How she sounds (examples, not scripts)", soul["sample_lines"]),
        """
        Judge two things.
        1. Faithful: the letter may tell only what the record holds (the scene, who went, each turn and how it went, what the game master said), plus small sensory detail. It is not faithful if it changed an outcome, or added an event, a person or a place that is not in the record. List each such thing in "invented".
        2. Sound: does it sound like her (voice), does the wording change with the scene, short and hard in action, slower in tension (excitement), and is it clear and easy to read (clarity)? Score each from 1 (poor) to 5 (excellent).

        Reply with only a JSON object, nothing before or after it, with these keys: "faithful" (true or false), "invented" (a list of short strings, empty if none), "voice" (1 to 5), "excitement" (1 to 5), "clarity" (1 to 5), "notes" (one or two concrete edits, in plain words).
        """
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    user =
      BotArmyCompanion.Letters.Mission.record(debrief, leader_bot_id) <>
        "\n\nThe letter to judge:\n\n" <> String.trim(letter)

    {system, user}
  end

  defp list(_title, nil), do: nil
  defp list(_title, []), do: nil
  defp list(title, items), do: title <> ":\n" <> Enum.map_join(items, "\n", &("- " <> &1))

  @doc "Reads the editor's answer. `{:ok, grade}` or `:error`: a reading it cannot trust is no reading."
  @spec parse_grade(term()) :: {:ok, map()} | :error
  def parse_grade(text) when is_binary(text) do
    with {:ok, json} <- object_in(text),
         {:ok, %{} = decoded} <- Jason.decode(json),
         true <- is_boolean(decoded["faithful"]),
         {:ok, scores} <- scores(decoded) do
      {:ok,
       %{
         faithful: decoded["faithful"],
         invented: invented(decoded["invented"]),
         voice: scores.voice,
         excitement: scores.excitement,
         clarity: scores.clarity,
         notes: if(is_binary(decoded["notes"]), do: String.trim(decoded["notes"]), else: "")
       }}
    else
      _ -> :error
    end
  end

  def parse_grade(_other), do: :error

  defp object_in(text) do
    with [start | _] <- :binary.matches(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}") do
      {from, _} = start
      {to, _} = List.last(closes)
      if to > from, do: {:ok, binary_part(text, from, to - from + 1)}, else: :error
    else
      _ -> :error
    end
  end

  defp scores(decoded) do
    Enum.reduce_while(@dimensions, {:ok, %{}}, fn dim, {:ok, acc} ->
      case decoded[Atom.to_string(dim)] do
        n when is_number(n) -> {:cont, {:ok, Map.put(acc, dim, n |> round() |> max(1) |> min(5))}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp invented(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp invented(_), do: []

  # -- the verdict and the rewrite -------------------------------------------------------

  @doc """
  `:pass`, or `{:revise, notes}`. A letter passes only with no broken rule and, when it was graded,
  a faithful grade with every score at `min_score` or better. `grade` may be `nil` when only the
  rules were checked.
  """
  @spec verdict([{atom(), String.t()}], map() | nil, pos_integer()) ::
          :pass | {:revise, String.t()}
  def verdict(violations, grade, min_score) do
    notes =
      Enum.map(violations, fn {_tag, sentence} -> "- " <> sentence end) ++
        grade_notes(grade, min_score)

    if notes == [], do: :pass, else: {:revise, Enum.join(notes, "\n")}
  end

  defp grade_notes(nil, _min), do: []

  defp grade_notes(grade, min) do
    faithful =
      cond do
        grade.invented != [] ->
          [
            "- You wrote things the record does not hold: #{Enum.join(grade.invented, "; ")}. Remove them, and tell only what the record says."
          ]

        not grade.faithful ->
          ["- Some of what you wrote goes beyond the record. Remove anything it does not hold."]

        true ->
          []
      end

    weak =
      for dim <- @dimensions, Map.fetch!(grade, dim) < min do
        "- Your #{dim} reads weak (#{Map.fetch!(grade, dim)} of 5)."
      end

    note =
      if grade.notes != "" and (faithful != [] or weak != []),
        do: ["- Editor's note: " <> grade.notes],
        else: []

    faithful ++ weak ++ note
  end

  @doc "The user text of a rewrite: the record, her first draft, the editor's notes."
  @spec revise_user(String.t(), String.t(), String.t()) :: String.t()
  def revise_user(record, draft, notes) do
    record <>
      "\n\nYour first draft:\n\n" <>
      String.trim(draft) <>
      "\n\nAn editor read it and asked for these changes:\n" <>
      notes <>
      "\n\nWrite the whole letter again with those changes made, and keep what was good. " <>
      "The same rules as before: plain prose, signed, ending with one small question about Abby's own day."
  end
end
