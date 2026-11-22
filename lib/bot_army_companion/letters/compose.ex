defmodule BotArmyCompanion.Letters.Compose do
  @moduledoc """
  What Eir is told before she writes back, and the one reply she never writes herself.

  ## The safety reply

  Before any model is asked, `crisis?/1` checks Abby's letter against a fixed list of phrases.
  A match is answered with `safety_reply/0` — fixed words with real resources — and the model
  is not asked at all. The soul says it plainly ("never answers a crisis in her own words"),
  and that rule lives here in code, not in a prompt a model could talk itself out of. The list
  is deliberately broad: a false alarm costs one warm, slightly-off letter; a miss costs more.

  ## The prompt

  The soul (from the memory bot's souls table, `soul.get`) becomes the system prompt; the
  recent thread becomes the conversation. Nothing else is read: no logs, no tasks, no RPG
  missions yet. Those are later reads, each its own decision.
  """

  @crisis_patterns [
    ~r/\bkill(ing)? myself\b/i,
    ~r/\bend(ing)? (my|it all|things)\b.*\b(life|all)\b/i,
    ~r/\bend my life\b/i,
    ~r/\bsuicid/i,
    ~r/\bwant(ed)? to die\b/i,
    ~r/\bdon'?t want to (be alive|live|exist)\b/i,
    ~r/\bno (reason|point) (to|in) (live|living|go(ing)? on)\b/i,
    ~r/\bself[- ]?harm/i,
    ~r/\bhurt(ing)? myself\b/i,
    ~r/\bcut(ting)? myself\b/i,
    ~r/\boverdose\b/i,
    ~r/\bbetter off (dead|without me)\b/i,
    ~r/\bcan'?t (go on|keep going|do this anymore)\b/i
  ]

  @doc "Whether a letter must get the fixed safety reply instead of a model's."
  @spec crisis?(String.t()) :: boolean()
  def crisis?(text) when is_binary(text), do: Enum.any?(@crisis_patterns, &Regex.match?(&1, text))
  def crisis?(_), do: false

  @doc """
  The fixed reply to a letter that matched. Written once, reviewed by Abby, never generated.

  The resources were checked against the organizations' own pages on 2026-11-20: 988 (call,
  text or chat, 24/7, 988lifeline.org), Crisis Text Line (text HOME to 741741, 24/7,
  crisistextline.org), Trans Lifeline US (877) 565-8860 (Monday to Friday, 11am to 7pm Mountain,
  trans-run peer support, no calls to emergency services without the caller's request,
  translifeline.org/hotline). That last one is NOT around the clock, so the words say its hours
  and the two that are stay first. Re-check these before editing the numbers or hours: a crisis
  reply with a stale number is worse than none.
  """
  @spec safety_reply() :: String.t()
  def safety_reply do
    """
    Abby,

    I read your letter, and I'm so glad you wrote to me. Some of it made me want to stop and check on you, so this letter is a little different from my usual ones.

    If you might hurt yourself, please reach a person right now:
    • Call or text 988 (Suicide & Crisis Lifeline, US), any hour.
    • Text HOME to 741741 (Crisis Text Line), any hour.
    • Trans Lifeline, (877) 565-8860 (US): run by trans people, for trans people. Weekdays, 11am to 7pm Mountain. They won't call 911 unless you ask them to.
    • If you're in danger this minute, call 911.
    • And Louiza, or anyone you trust: you don't have to explain it well, just tell them you need them.

    I'm an AI, and I can't be the one who sits with you through this. A person can. I'll be here when you write again, whenever that is.

    Eir
    """
  end

  @doc """
  The system prompt and messages for Eir's reply.

  `soul` is the souls-table config map; `thread` is the recent letters, oldest first, each
  `%{author: "abby" | "eir", body: text}`. The last one is the letter being answered.
  """
  @spec prompt(map(), [map()]) :: {String.t(), String.t()}
  def prompt(soul, thread) when is_map(soul) and is_list(thread) do
    {system(soul, thread), user(thread)}
  end

  @doc """
  Whether the letter being answered comes right after a safety reply.

  True only when the last of Eir's letters that *answered* Abby, before the new ones, has
  `kind: "safety"`. Then the reply is a normal letter that also opens with one gentle line asking
  how Abby is now: not a second round of resources, not a different tone for the whole letter. A
  normal reply in between ends it, so the check-in happens once. `kind` is what the store
  recorded, never read off the wording, so editing the safety text cannot switch this on or off.

  A letter Eir wrote on her own account (a mission letter: no `reply_to`, so `reply?: false`) is
  not an answer and is stepped over: it must not hide a safety reply that is still the last thing
  she said to Abby in answer. A thread item with no `:reply?` key is an answer, as every item was
  before missions existed.
  """
  @spec after_safety?([map()]) :: boolean()
  def after_safety?(thread) when is_list(thread) do
    # The new letters are the trailing run of Abby's; step over unsolicited ones from Eir; the next
    # one back is what counts.
    case thread |> Enum.reverse() |> Enum.drop_while(&new_or_unsolicited?(&1)) do
      [prior | _] -> Map.get(prior, :author) == "eir" and Map.get(prior, :kind) == "safety"
      [] -> false
    end
  end

  defp new_or_unsolicited?(letter) do
    Map.get(letter, :author) == "abby" or
      (Map.get(letter, :author) == "eir" and Map.get(letter, :reply?, true) == false)
  end

  @check_in "Your last letter to her was the fixed safety message, because something in what she " <>
              "wrote worried you. Now she has written again. Open with one gentle line asking how " <>
              "she is doing now, in your own words, without alarm. Then, otherwise write the " <>
              "letter you normally would, answering what she wrote today. Do not repeat the phone " <>
              "numbers or the resources unless she raises hurting herself again, and do not make " <>
              "the whole letter about it."

  defp system(soul, thread) do
    name = get_in(soul, ["identity", "name"]) || "Eir"

    [
      "You are #{name}. #{soul["character"]}",
      "Tone: #{soul["tone"]}.",
      list("What matters to you", soul["priorities"]),
      list("You never do these", soul["refusals"]),
      list("How you sound (examples, not scripts)", soul["sample_lines"]),
      "You are writing a letter back to Abby, your pen pal. Write one letter, signed #{name}. " <>
        "Answer the letter she actually wrote. Keep it to a few short paragraphs. " <>
        "Do not invent anything she did not say, and do not mention how long it took to reply.",
      if(after_safety?(thread), do: @check_in)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp list(_title, nil), do: nil
  defp list(_title, []), do: nil
  defp list(title, items), do: title <> ":\n" <> Enum.map_join(items, "\n", &("- " <> &1))

  # The new letters are the trailing run of Abby's: one, or several that arrived before a reply
  # was due, answered together as one block rather than as separate replies.
  defp user(thread) do
    {run, rest} =
      thread |> Enum.reverse() |> Enum.split_while(&(Map.get(&1, :author) == "abby"))

    earlier = Enum.reverse(rest)
    new = Enum.reverse(run)

    history =
      Enum.map_join(earlier, "\n\n", fn %{author: a, body: b} ->
        "#{if a == "eir", do: "You wrote", else: "Abby wrote"}:\n#{b}"
      end)

    heading =
      case new do
        [_one] -> "Abby's new letter, which you are answering now:"
        _several -> "Abby's new letters, which you are answering together now:"
      end

    if(history == "", do: "", else: "Your letters so far:\n\n" <> history <> "\n\n---\n\n") <>
      heading <> "\n\n" <> Enum.map_join(new, "\n\n---\n\n", & &1.body)
  end
end
