defmodule BotArmyCompanion.LettersGraderTest do
  @moduledoc """
  The check a mission letter passes before it is stored.

  Two kinds of judgment, kept apart on purpose. The rules are code and a letter either breaks one or
  does not: markdown, a missing signature, steering, no closing question, a companion never named. The
  grade is a model's read of what code cannot see, whether the letter stays inside the record and
  sounds like her, with Eir's own soul as the standard rather than anyone's taste written into a
  prompt. A letter goes out only when both are clean.
  """

  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyCompanion.Letters.Grader

  @soul %{
    "identity" => %{"name" => "Eir"},
    "character" => "A pen pal who writes back.",
    "tone" => "warm, unhurried, a little playful",
    "sample_lines" => ["The guard turned. I did not run."]
  }

  @debrief %{
    "scene" => "A rooftop above the Nexus, and the contact is late.",
    "party" => [
      %{"name" => "Eir", "bot_id" => "companion_bot"},
      %{"name" => "Mara Voss", "bot_id" => "gtd_bot"},
      %{"name" => "Kira \"Ghost\" Tanaka", "bot_id" => "llm_bot"}
    ],
    "turns" => [
      %{"round" => 1, "name" => "Eir", "action" => "persuade", "outcome" => "failure"}
    ],
    "story" => ["Eir's pitch falls flat."]
  }

  @good """
  Abby,

  The roof was cold and the contact never came. I talked first, because I always do, and it fell flat. Then Mara tried the net and slipped, and Kira's plea got rerouted into a wall of firewall. Three of us, three misses.

  I liked it anyway. Nobody on that roof stopped trying, and I would take Mara and Kira with me again.

  What was the best part of your day?

  Eir
  """

  defp rules(text), do: Grader.rules(text, @debrief, "companion_bot", @soul)
  defp tags(text), do: text |> rules() |> Enum.map(&elem(&1, 0))

  describe "rules/4" do
    test "a good letter breaks none" do
      assert rules(@good) == []
    end

    test "markdown, in any of its common forms" do
      for bad <- [
            String.replace(@good, "roof was cold", "**roof** was cold"),
            String.replace(@good, "roof was cold", "__roof__ was cold"),
            String.replace(@good, "Abby,", "# Abby,"),
            String.replace(@good, "I liked it anyway.", "- I liked it anyway."),
            String.replace(@good, "I liked it anyway.", "* I liked it anyway."),
            String.replace(@good, "I liked it anyway.", "1. I liked it anyway."),
            String.replace(@good, "firewall", "`firewall`")
          ] do
        assert :markdown in tags(bad), bad
      end

      refute :markdown in tags(@good)
    end

    test "a hyphen or an asterisk inside a sentence is not markdown" do
      text = String.replace(@good, "Three of us", "Three of us (well - two and a half)")
      refute :markdown in tags(text)
    end

    test "too short, too long, and a single block" do
      assert :too_short in tags("Abby,\n\nIt was cold. Mara and Kira came. Why?\n\nEir")
      assert :too_long in tags(@good <> "\n\n" <> String.duplicate("More. ", 700) <> "\n\nEir")

      one_block = @good |> String.replace("\n\n", " ") |> String.trim()
      assert :one_block in tags(one_block)
    end

    test "must end signed with her name, and the name is the soul's" do
      assert :no_signature in tags(String.replace(@good, "\n\nEir\n", "\n"))
      assert :no_signature in tags(@good <> "\nP.S. one more thing")

      assert rules(String.replace(@good, "Eir", "Eir.")) == []

      renamed = %{@soul | "identity" => %{"name" => "Aela"}}

      assert Enum.any?(
               Grader.rules(@good, @debrief, "companion_bot", renamed),
               &(elem(&1, 0) == :no_signature)
             )
    end

    test "must close, before the signature, with a question" do
      no_question =
        String.replace(@good, "What was the best part of your day?", "I hope your day was good.")

      assert :no_closing_question in tags(no_question)

      # a question earlier in the letter does not count
      early = String.replace(@good, "I liked it anyway.", "Why did I go? I liked it anyway.")

      assert :no_closing_question in tags(
               String.replace(early, "What was the best part of your day?", "Good night.")
             )
    end

    test "every companion is called by name, first names are enough" do
      assert :companion_unnamed in tags(String.replace(@good, "Kira", "the runner"))
      assert :companion_unnamed in tags(String.replace(@good, "Mara", "the fixer"))

      {_tag, detail} =
        Enum.find(
          rules(String.replace(@good, "Kira", "the runner")),
          &(elem(&1, 0) == :companion_unnamed)
        )

      assert detail =~ "Kira"
      refute detail =~ "Mara"
    end

    test "a name inside a longer word is not the name" do
      assert :companion_unnamed in tags(String.replace(@good, "Kira", "Kirana"))
      assert :companion_unnamed in tags(String.replace(@good, "Mara", "Maraschino"))
    end

    test "steering: no shoulds, musts or needs" do
      for bad <- [
            "you should rest",
            "You must try again",
            "you need to get out more",
            "You have to see this",
            "you ought to write back"
          ] do
        text = String.replace(@good, "I liked it anyway.", "I liked it anyway, and #{bad}.")
        assert :steering in tags(text), bad
      end

      refute :steering in tags(
               String.replace(
                 @good,
                 "I liked it anyway.",
                 "Should I have run? I liked it anyway."
               )
             )
    end

    test "never counts the time since she last wrote as a fault" do
      for bad <- [
            "It has been a while",
            "It's been so long",
            "I haven't heard from you",
            "Long time no letter"
          ] do
        text = String.replace(@good, "I liked it anyway.", "#{bad}. I liked it anyway.")
        assert :gap_fault in tags(text), bad
      end
    end

    test "each broken rule is reported once, with a sentence an editor could act on" do
      bad = String.replace(@good, "roof was cold", "**roof** and **cold**")
      assert [{:markdown, detail}] = Enum.filter(rules(bad), &(elem(&1, 0) == :markdown))
      assert is_binary(detail) and detail != ""
    end
  end

  describe "grade_prompt/4" do
    test "an editor's brief: her soul as the standard, the record, the letter, and a JSON-only answer" do
      {system, user} = Grader.grade_prompt(@soul, @good, @debrief, "companion_bot")

      assert system =~ "You are an editor"
      assert system =~ "A pen pal who writes back."
      assert system =~ "warm, unhurried"
      assert system =~ "The guard turned. I did not run."
      assert system =~ ~r/only a JSON object/i
      for key <- ~w(faithful invented voice excitement clarity notes), do: assert(system =~ key)

      assert user =~ "A rooftop above the Nexus"
      assert user =~ "Eir (you) tried to persuade"
      assert user =~ "The letter to judge:"
      assert user =~ "The roof was cold and the contact never came."
    end

    test "the editor is told the letter may not change an outcome or add an event" do
      {system, _} = Grader.grade_prompt(@soul, @good, @debrief, "companion_bot")
      assert system =~ "changed an outcome"
      assert system =~ "not in the record"
    end
  end

  describe "parse_grade/1" do
    @json ~s({"faithful": true, "invented": [], "voice": 4, "excitement": 3, "clarity": 5, "notes": "Open on the cold."})

    test "reads a bare JSON object" do
      assert {:ok, g} = Grader.parse_grade(@json)

      assert g == %{
               faithful: true,
               invented: [],
               voice: 4,
               excitement: 3,
               clarity: 5,
               notes: "Open on the cold."
             }
    end

    test "finds the object inside a fence or a sentence" do
      assert {:ok, %{voice: 4}} = Grader.parse_grade("Here you go:\n```json\n#{@json}\n```")
      assert {:ok, %{voice: 4}} = Grader.parse_grade("Sure. #{@json} Hope that helps.")
    end

    test "scores are held to 1 to 5, and a score that is not a number is a failed read" do
      assert {:ok, %{voice: 5, excitement: 1}} =
               Grader.parse_grade(
                 ~s({"faithful": true, "voice": 9, "excitement": 0, "clarity": 3})
               )

      assert :error =
               Grader.parse_grade(
                 ~s({"faithful": true, "voice": "great", "excitement": 3, "clarity": 3})
               )
    end

    test "faithful must be said, and be a boolean" do
      assert :error = Grader.parse_grade(~s({"voice": 4, "excitement": 3, "clarity": 3}))

      assert :error =
               Grader.parse_grade(
                 ~s({"faithful": "yes", "voice": 4, "excitement": 3, "clarity": 3})
               )
    end

    test "invented is a list of text, and anything else is none" do
      assert {:ok, %{invented: ["a dragon", "a boat"]}} =
               Grader.parse_grade(
                 ~s({"faithful": false, "invented": ["a dragon", 7, "a boat"], "voice": 3, "excitement": 3, "clarity": 3})
               )

      assert {:ok, %{invented: []}} =
               Grader.parse_grade(
                 ~s({"faithful": true, "invented": "none", "voice": 3, "excitement": 3, "clarity": 3})
               )
    end

    test "notes are optional, and text that holds no object is a failed read" do
      assert {:ok, %{notes: ""}} =
               Grader.parse_grade(
                 ~s({"faithful": true, "voice": 3, "excitement": 3, "clarity": 3})
               )

      for bad <- ["", "no json here", "{broken", nil, 42],
          do: assert(:error = Grader.parse_grade(bad))
    end
  end

  describe "verdict/3" do
    @pass %{faithful: true, invented: [], voice: 4, excitement: 4, clarity: 4, notes: "Lovely."}

    test "clean rules and a good grade pass" do
      assert :pass = Grader.verdict([], @pass, 3)
    end

    test "any broken rule is a revision, and its note is the rule's own sentence" do
      assert {:revise, notes} = Grader.verdict([{:markdown, "Write plain prose."}], @pass, 3)
      assert notes =~ "Write plain prose."
    end

    test "a letter that goes beyond the record is a revision that names what was invented" do
      grade = %{@pass | faithful: false, invented: ["a dragon over the roof"]}
      assert {:revise, notes} = Grader.verdict([], grade, 3)
      assert notes =~ "a dragon over the roof"
      assert notes =~ "Remove"
    end

    test "unfaithful with nothing named is still a revision" do
      assert {:revise, _} = Grader.verdict([], %{@pass | faithful: false}, 3)
    end

    test "a score under the bar is a revision, and the editor's notes ride along" do
      assert {:revise, notes} =
               Grader.verdict([], %{@pass | excitement: 2, notes: "Open on the cold."}, 3)

      assert notes =~ "excitement"
      assert notes =~ "Open on the cold."
    end

    test "a score at the bar passes, and the bar is the caller's" do
      assert :pass = Grader.verdict([], %{@pass | clarity: 3}, 3)
      assert {:revise, _} = Grader.verdict([], %{@pass | clarity: 3}, 4)
    end

    test "rules alone, with no grade, still decide" do
      assert :pass = Grader.verdict([], nil, 3)
      assert {:revise, _} = Grader.verdict([{:markdown, "x"}], nil, 3)
    end
  end

  describe "revise_user/3" do
    test "the record, her first draft, and the editor's notes, asking for the whole letter again" do
      user = Grader.revise_user("THE RECORD", "my first draft", "- Remove the dragon.")

      assert user =~ "THE RECORD"
      assert user =~ "my first draft"
      assert user =~ "- Remove the dragon."
      assert user =~ ~r/write the whole letter again/i
      assert user =~ "keep what was good"
    end
  end
end
