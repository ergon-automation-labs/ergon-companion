defmodule BotArmyCompanion.ReflectionsTest do
  @moduledoc """
  The decisions `BotArmyCompanion.Reflections` makes before a database is
  involved, and the shape it puts on the wire afterwards.

  The live-Postgres counterpart lives in `reflections_db_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag :stores

  alias BotArmyCompanion.Reflection
  alias BotArmyCompanion.Reflections

  describe "prepare/1 — what is worth keeping" do
    test "her words, untouched" do
      assert {:ok, prepared} = Reflections.prepare(%{"text" => "One drawer is enough."})

      assert prepared.text == "One drawer is enough."
      assert prepared.prompt == nil
      assert prepared.captured_at == nil
    end

    test "spacing and newlines are hers, so they are not trimmed away" do
      text = "  the first line\n\n  the second line  "

      assert {:ok, prepared} = Reflections.prepare(%{"text" => text})
      assert prepared.text == text
    end

    test "the question she was answering is kept when it is sent" do
      assert {:ok, prepared} =
               Reflections.prepare(%{
                 "text" => "I did not get out of bed until noon.",
                 "prompt" => "How was today?"
               })

      assert prepared.prompt == "How was today?"
    end

    test "the publisher's timestamp is read as an instant" do
      assert {:ok, prepared} =
               Reflections.prepare(%{
                 "text" => "x",
                 "timestamp" => "2026-09-26T03:51:29Z"
               })

      assert DateTime.to_iso8601(prepared.captured_at) == "2026-09-26T03:51:29Z"
    end

    test "a timestamp with an offset is understood as the same instant" do
      assert {:ok, prepared} =
               Reflections.prepare(%{
                 "text" => "x",
                 "timestamp" => "2026-09-26T05:51:29+02:00"
               })

      assert DateTime.to_iso8601(prepared.captured_at) == "2026-09-26T03:51:29Z"
    end

    test "a timestamp nobody can read is left nil rather than invented" do
      assert {:ok, prepared} =
               Reflections.prepare(%{"text" => "still hers", "timestamp" => "yesterday-ish"})

      assert prepared.captured_at == nil
      assert prepared.text == "still hers"
    end

    test "a timestamp that is not text at all is left nil too" do
      assert {:ok, prepared} = Reflections.prepare(%{"text" => "x", "timestamp" => 1_777_000_000})

      assert prepared.captured_at == nil
    end

    test "a wordless reflection is refused" do
      assert {:error, :no_text} = Reflections.prepare(%{"text" => ""})
      assert {:error, :no_text} = Reflections.prepare(%{"text" => "   \n  "})
      assert {:error, :no_text} = Reflections.prepare(%{"text" => nil})
      assert {:error, :no_text} = Reflections.prepare(%{"text" => 42})
      assert {:error, :no_text} = Reflections.prepare(%{"prompt" => "How was today?"})
      assert {:error, :no_text} = Reflections.prepare(%{})
    end

    test "a reflection longer than the ceiling is refused, not cut in half" do
      max = Reflection.max_text()
      assert {:ok, _prepared} = Reflections.prepare(%{"text" => String.duplicate("a", max)})

      assert {:error, {:too_long, ^max}} =
               Reflections.prepare(%{"text" => String.duplicate("a", max + 1)})
    end

    test "a prompt that is not text is refused" do
      assert {:error, :bad_prompt} = Reflections.prepare(%{"text" => "x", "prompt" => 7})
      assert {:error, :bad_prompt} = Reflections.prepare(%{"text" => "x", "prompt" => %{}})
    end

    test "a payload that is not an object is refused" do
      assert {:error, :not_a_map} = Reflections.prepare("just text")
      assert {:error, :not_a_map} = Reflections.prepare(nil)
      assert {:error, :not_a_map} = Reflections.prepare([%{"text" => "x"}])
    end
  end

  describe "view/1 — what a reader is told" do
    test "her words, the counts, and the two different times" do
      row = %Reflection{
        id: "6f6e2f7c-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
        text: "line one\nline two",
        prompt: "How was today?",
        captured_at: ~U[2026-09-26 03:51:29.000000Z],
        inserted_at: ~U[2026-09-26 03:51:30.123456Z],
        updated_at: ~U[2026-09-26 03:51:30.123456Z]
      }

      view = Reflections.view(row)

      assert view["id"] == "6f6e2f7c-1a2b-4c3d-8e9f-0a1b2c3d4e5f"
      assert view["text"] == "line one\nline two"
      assert view["prompt"] == "How was today?"
      assert view["captured_at"] == "2026-09-26T03:51:29.000000Z"
      assert view["stored_at"] == "2026-09-26T03:51:30.123456Z"
      assert view["chars"] == String.length("line one\nline two")
    end

    test "a reflection with no stated capture time says so, rather than borrowing one" do
      row = %Reflection{text: "x", captured_at: nil}

      assert Reflections.view(row)["captured_at"] == nil
    end

    test "the character count follows the words it counts" do
      assert Reflections.view(%Reflection{text: "é"})["chars"] == 1
      assert Reflections.view(%Reflection{text: ""})["chars"] == 0
      assert Reflections.view(%Reflection{text: nil})["chars"] == 0
    end
  end

  describe "explain/1 — refusals as sentences" do
    test "every refusal this module raises has a sentence" do
      reasons = [
        :no_text,
        {:too_long, Reflection.max_text()},
        :bad_prompt,
        :not_a_map,
        :bad_limit,
        :not_found,
        :invalid,
        :store_failed
      ]

      for reason <- reasons do
        sentence = Reflections.explain(reason)
        assert is_binary(sentence)
        assert sentence != ""
      end
    end

    test "the ceiling is named in the sentence that refuses it" do
      assert Reflections.explain({:too_long, Reflection.max_text()}) =~
               Integer.to_string(Reflection.max_text())
    end

    test "an unknown reason still produces a sentence rather than a crash" do
      assert Reflections.explain(:something_new) == "the reflection store could not answer"
    end
  end

  describe "the boundaries it advertises" do
    test "the ceiling lives in the schema, and the service reads it from there" do
      assert Reflections.max_text() == Reflection.max_text()
      assert Reflection.max_text() > 0
    end

    test "the default limit is inside the ceiling" do
      assert Reflections.default_limit() >= 1
      assert Reflections.default_limit() <= Reflections.max_limit()
    end
  end
end
