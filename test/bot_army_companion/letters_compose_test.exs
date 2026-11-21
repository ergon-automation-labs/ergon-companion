defmodule BotArmyCompanion.LettersComposeTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyCompanion.Letters.Compose

  describe "crisis?/1" do
    test "catches the phrases that must get the fixed reply" do
      for text <- [
            "some days I want to die",
            "I keep thinking about killing myself",
            "thinking about suicide again",
            "I've been self-harming",
            "I don't want to be alive anymore",
            "everyone would be better off without me",
            "I can't go on like this",
            "I want to end my life"
          ] do
        assert Compose.crisis?(text), text
      end
    end

    test "ordinary heavy letters are not crises" do
      for text <- [
            "work was brutal and I'm exhausted",
            "I died laughing at the owl",
            "the deadline is killing me",
            "I'm sad about my sister",
            "let's end the day with a walk"
          ] do
        refute Compose.crisis?(text), text
      end
    end
  end

  test "the safety reply names real resources and says she is an AI" do
    reply = Compose.safety_reply()
    assert reply =~ "988"
    assert reply =~ "741741"
    assert reply =~ "911"
    assert reply =~ "I'm an AI"
  end

  test "the trans line is the US one, says its hours, and never looks around the clock" do
    reply = Compose.safety_reply()
    assert reply =~ "(877) 565-8860"
    refute reply =~ "330-6366", "the Canada line is not for a US reader"
    assert reply =~ "Weekdays, 11am to 7pm Mountain"
    assert reply =~ "They won't call 911 unless you ask them to"
  end

  test "the always-on lines come before the one with hours" do
    reply = Compose.safety_reply()
    {i988, _} = :binary.match(reply, "988")
    {itext, _} = :binary.match(reply, "741741")
    {itrans, _} = :binary.match(reply, "565-8860")
    assert i988 < itrans and itext < itrans
    assert reply =~ "Call or text 988 (Suicide & Crisis Lifeline, US), any hour"
    assert reply =~ "741741 (Crisis Text Line), any hour"
  end

  describe "prompt/2" do
    @soul %{
      "identity" => %{"name" => "Eir"},
      "character" => "A pen pal who writes back.",
      "tone" => "warm",
      "priorities" => ["answering the letter that was actually written"],
      "refusals" => ["never claims to be human"],
      "sample_lines" => ["Your letter came this morning."]
    }

    test "the soul becomes the system prompt" do
      {system, _user} = Compose.prompt(@soul, [%{author: "abby", body: "hi"}])
      assert system =~ "You are Eir. A pen pal who writes back."
      assert system =~ "- never claims to be human"
      assert system =~ "signed Eir"
    end

    test "the thread becomes the message, ending on the letter being answered" do
      thread = [
        %{author: "abby", body: "first"},
        %{author: "eir", body: "reply one"},
        %{author: "abby", body: "the new one"}
      ]

      {_system, user} = Compose.prompt(@soul, thread)
      assert user =~ "Abby wrote:\nfirst"
      assert user =~ "You wrote:\nreply one"
      assert String.ends_with?(user, "answering now:\n\nthe new one")
    end

    test "a first letter has no history section" do
      {_s, user} = Compose.prompt(@soul, [%{author: "abby", body: "hello"}])
      refute user =~ "so far"
    end

    test "several unanswered letters are answered together, in order, as one block" do
      thread = [
        %{author: "abby", body: "old"},
        %{author: "eir", body: "reply to old"},
        %{author: "abby", body: "evening one"},
        %{author: "abby", body: "evening two"},
        %{author: "abby", body: "evening three"}
      ]

      {_system, user} = Compose.prompt(@soul, thread)

      assert user =~ "Abby wrote:\nold"
      assert user =~ "You wrote:\nreply to old"
      assert user =~ "which you are answering together now"
      assert user =~ "evening one\n\n---\n\nevening two\n\n---\n\nevening three"
      # The earlier ones are not repeated as history, and the singular wording is not used.
      refute user =~ "Abby wrote:\nevening one"
      refute user =~ "answering now:"
    end
  end

  describe "the letter after a safety reply: a normal letter with one gentle check-in" do
    @soul %{"identity" => %{"name" => "Eir"}, "character" => "A pen pal.", "tone" => "warm"}

    defp after_safety do
      [
        %{author: "abby", body: "some days I want to die", kind: "normal"},
        %{author: "eir", body: Compose.safety_reply(), kind: "safety"},
        %{author: "abby", body: "I'm okay today. Work was fine.", kind: "normal"}
      ]
    end

    test "the immediately preceding safety reply asks for one gentle check-in" do
      assert Compose.after_safety?(after_safety())

      {system, user} = Compose.prompt(@soul, after_safety())
      assert system =~ "how she is doing now"
      assert system =~ "one gentle line"
      assert system =~ "otherwise write the letter you normally would"
      # She is told not to repeat the numbers unless Abby raises it again.
      assert system =~ "Do not repeat the phone numbers"
      # And the letter being answered is still the new one.
      assert String.ends_with?(user, "answering now:\n\nI'm okay today. Work was fine.")
    end

    test "an ordinary thread gets no check-in" do
      thread = [
        %{author: "abby", body: "hi", kind: "normal"},
        %{author: "eir", body: "hello", kind: "normal"},
        %{author: "abby", body: "how are you", kind: "normal"}
      ]

      refute Compose.after_safety?(thread)
      {system, _} = Compose.prompt(@soul, thread)
      refute system =~ "how she is doing now"
    end

    test "only the very next letter: a normal reply in between ends it" do
      thread =
        after_safety() ++
          [
            %{author: "eir", body: "glad to hear it", kind: "normal"},
            %{author: "abby", body: "third letter", kind: "normal"}
          ]

      refute Compose.after_safety?(thread)
    end

    test "letters with no kind are normal, and a first letter has no one before it" do
      refute Compose.after_safety?([%{author: "abby", body: "hi"}])
      refute Compose.after_safety?([%{author: "eir", body: "x"}, %{author: "abby", body: "y"}])
      assert {_system, _user} = Compose.prompt(@soul, [%{author: "abby", body: "hi"}])
    end

    test "the check-in still applies when several letters arrive after the safety reply" do
      thread = [
        %{author: "abby", body: "dark one", kind: "normal"},
        %{author: "eir", body: Compose.safety_reply(), kind: "safety"},
        %{author: "abby", body: "next morning, a", kind: "normal"},
        %{author: "abby", body: "next morning, b", kind: "normal"}
      ]

      assert Compose.after_safety?(thread)
      {system, user} = Compose.prompt(@soul, thread)
      assert system =~ "how she is doing now"
      assert user =~ "answering together now"
    end

    test "kind is recorded, not guessed from the wording" do
      # The same words as a normal letter are not a safety reply, so an edit to the safety
      # wording later cannot silently turn the check-in off (or on).
      thread = [
        %{author: "abby", body: "a", kind: "normal"},
        %{author: "eir", body: Compose.safety_reply(), kind: "normal"},
        %{author: "abby", body: "b", kind: "normal"}
      ]

      refute Compose.after_safety?(thread)
    end
  end
end
