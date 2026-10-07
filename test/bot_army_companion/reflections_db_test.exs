defmodule BotArmyCompanion.ReflectionsDbTest do
  @moduledoc """
  Her reflections against a live Postgres.

  Excluded from the default suite (`test_helper.exs`); run with
  `mix test --include integration`. `config/test.exs` points at a dedicated
  *test* database, never the companion's production one.

  The pure tests beside this file prove the decisions; this one proves that the
  words survive the store: that they come back exactly as they went in, that the
  newest is first, that an unreadable timestamp costs her nothing, that a bad
  limit is a refusal rather than a silent default, and that an empty store
  *answers* — because the difference between "nothing is there" and "nothing
  answered" is the whole point of the module.
  """

  use ExUnit.Case, async: false

  @moduletag :stores

  alias BotArmyCompanion.Reflection
  alias BotArmyCompanion.Reflections
  alias BotArmyCompanion.Repo
  alias BotArmyCompanion.Test.PostgresHelper

  describe "her reflections (live Postgres)" do
    @describetag :integration

    setup do
      start_supervised!(Repo)
      PostgresHelper.reset_schema!(Repo)
      assert :ok = BotArmyCompanion.Release.migrate()
      :ok
    end

    test "her words come back exactly as they went in" do
      text = "  I said I would rest today.\n\n  I did not rest today.  "

      assert {:ok, stored, :created} =
               Reflections.capture(%{
                 "text" => text,
                 "prompt" => "How was today?",
                 "timestamp" => "2026-09-26T03:51:29Z"
               })

      assert stored["text"] == text
      assert stored["chars"] == String.length(text)
      assert stored["prompt"] == "How was today?"
      assert stored["captured_at"] == "2026-09-26T03:51:29.000000Z"
      assert is_binary(stored["stored_at"])
      assert is_binary(stored["id"])

      assert {:ok, [row]} = Reflections.list(nil)
      assert row == stored
    end

    test "the newest reflection comes first" do
      for text <- ["first", "second", "third"] do
        assert {:ok, _view, :created} = Reflections.capture(%{"text" => text})
      end

      assert {:ok, rows} = Reflections.list(nil)
      assert Enum.map(rows, & &1["text"]) == ["third", "second", "first"]
    end

    test "an unreadable timestamp does not cost her the words" do
      assert {:ok, stored, :created} =
               Reflections.capture(%{"text" => "still hers", "timestamp" => "yesterday-ish"})

      assert stored["captured_at"] == nil
      assert stored["text"] == "still hers"

      assert {:ok, [row]} = Reflections.list(nil)
      assert row["captured_at"] == nil
      assert row["text"] == "still hers"
      assert is_binary(row["stored_at"])
    end

    test "a wordless reflection is refused, and nothing is written" do
      assert {:error, :no_text} = Reflections.capture(%{"text" => "   \n "})
      assert {:error, :no_text} = Reflections.capture(%{"prompt" => "How was today?"})

      assert {:ok, []} = Reflections.list(nil)
    end

    test "the ceiling refuses rather than truncating her sentence" do
      max = Reflection.max_text()

      assert {:error, {:too_long, ^max}} =
               Reflections.capture(%{"text" => String.duplicate("a", max + 1)})

      assert {:ok, []} = Reflections.list(nil)

      assert {:ok, stored, :created} =
               Reflections.capture(%{"text" => String.duplicate("a", max)})

      assert stored["chars"] == max
    end

    test "the database holds the line for a writer that walks past the service" do
      # No changeset, no validation: `text` is NOT NULL, so a wordless row is
      # refused by the store itself rather than kept as a blank reflection.
      assert_raise Postgrex.Error, fn -> Repo.insert!(%Reflection{}) end
    end

    test "the same key twice stores one reflection, and says which it is" do
      # The bug this key exists for: a phone fired one press twice, 30 ms apart,
      # and the store wrote two rows and asked for two answers.
      assert {:ok, first, :created} =
               Reflections.capture(%{"text" => "the same press", "dedupe_key" => "draft-1"})

      assert {:ok, second, :existing} =
               Reflections.capture(%{"text" => "the same press", "dedupe_key" => "draft-1"})

      assert second["id"] == first["id"]
      assert second["text"] == "the same press"
      assert {:ok, [_one]} = Reflections.list(nil)
    end

    test "a key minted for other words never swallows them" do
      # A key is a handle, not a filter over her words. A caller that reuses one
      # key for a different sentence loses the key, never the sentence.
      assert {:ok, first, :created} =
               Reflections.capture(%{"text" => "A", "dedupe_key" => "reused"})

      assert {:ok, second, :created} =
               Reflections.capture(%{"text" => "B", "dedupe_key" => "reused"})

      assert second["id"] != first["id"]

      assert {:ok, rows} = Reflections.list(nil)
      assert Enum.map(rows, & &1["text"]) == ["B", "A"]

      # ...and the key still names the words it was minted for.
      assert {:ok, again, :existing} =
               Reflections.capture(%{"text" => "A", "dedupe_key" => "reused"})

      assert again["id"] == first["id"]
    end

    test "without a key every call is its own reflection, exactly as before" do
      assert {:ok, one, :created} = Reflections.capture(%{"text" => "same words"})
      assert {:ok, two, :created} = Reflections.capture(%{"text" => "same words"})
      assert one["id"] != two["id"]
      assert {:ok, rows} = Reflections.list(nil)
      assert length(rows) == 2
    end

    test "a re-offer re-opens a transport failure, and clears what it left" do
      assert {:ok, stored, :created} = Reflections.capture(%{"text" => "the answer was lost"})

      assert {:ok, failed} =
               Reflections.record_answer(
                 Repo.get!(Reflection, stored["id"]),
                 {:error, :unavailable}
               )

      assert failed["answer"]["state"] == "failed"
      assert failed["answer"]["error"] == "unavailable"

      assert {:ok, reopened} = Reflections.reoffer(stored["id"])
      assert reopened["id"] == stored["id"]
      assert reopened["text"] == "the answer was lost"
      assert reopened["answer"]["state"] == "pending"
      assert reopened["answer"]["error"] == nil
      assert reopened["answer"]["text"] == nil
      assert reopened["answer"]["answered_at"] == nil
      assert reopened["answer"]["promise_flagged"] == false
    end

    test "a re-offer with answering switched off opens the row as unasked" do
      # A row opened as "pending" that nothing is going to answer would be a lie.
      assert {:ok, stored, :created} = Reflections.capture(%{"text" => "nobody is listening"})

      assert {:ok, _failed} =
               Reflections.record_answer(Repo.get!(Reflection, stored["id"]), {:error, :timeout})

      assert {:ok, reopened} = Reflections.reoffer(stored["id"], answer_state: "unasked")
      assert reopened["answer"]["state"] == "unasked"
      assert reopened["answer"]["error"] == nil

      assert {:error, :bad_answer_state} =
               Reflections.reoffer(stored["id"], answer_state: "perhaps")
    end

    test "a reflection the companion already answered is never re-opened" do
      assert {:ok, stored, :created} = Reflections.capture(%{"text" => "answered once"})

      assert {:ok, _answered} =
               Reflections.record_answer(
                 Repo.get!(Reflection, stored["id"]),
                 {:ok, %{text: "hello", model: "m"}}
               )

      assert {:error, {:not_failed, "answered"}} = Reflections.reoffer(stored["id"])
    end

    test "a model verdict is not re-offered, and an unknown row is not found" do
      assert {:ok, stored, :created} = Reflections.capture(%{"text" => "the model said no"})

      assert {:ok, _failed} =
               Reflections.record_answer(
                 Repo.get!(Reflection, stored["id"]),
                 {:error, :model_failed}
               )

      assert {:error, {:answer_was_not_transport, "model_failed"}} =
               Reflections.reoffer(stored["id"])

      assert {:error, :not_found} =
               Reflections.reoffer("6f6e2f7c-1a2b-4c3d-8e9f-0a1b2c3d4e5f")

      assert {:error, :missing_id} = Reflections.reoffer(nil)
      assert {:error, :missing_id} = Reflections.reoffer(42)
      assert {:error, :invalid_id} = Reflections.reoffer("not-a-uuid")
    end

    test "one reflection is read back by id" do
      assert {:ok, stored, :created} = Reflections.capture(%{"text" => "a single line"})
      assert {:ok, row} = Reflections.get(stored["id"])
      assert row == stored
    end

    test "a well-formed id the store does not hold is not found" do
      assert {:error, :not_found} =
               Reflections.get("6f6e2f7c-1a2b-4c3d-8e9f-0a1b2c3d4e5f")
    end

    test "an absent or malformed id never becomes a claim about the store" do
      # These three used to answer `:not_found` — a statement about what the
      # database holds, made without asking it. They are different facts and the
      # store is never touched to learn them.
      assert {:error, :missing_id} = Reflections.get(nil)
      assert {:error, :missing_id} = Reflections.get("")
      assert {:error, :missing_id} = Reflections.get(42)
      assert {:error, :invalid_id} = Reflections.get("not-a-uuid")
    end

    test "the limit is honoured, and a bad one is refused rather than defaulted" do
      for text <- ["one", "two", "three"] do
        assert {:ok, _view, :created} = Reflections.capture(%{"text" => text})
      end

      assert {:ok, rows} = Reflections.list(1)
      assert Enum.map(rows, & &1["text"]) == ["three"]

      assert {:ok, rows} = Reflections.list(2)
      assert Enum.map(rows, & &1["text"]) == ["three", "two"]

      assert {:ok, rows} = Reflections.list("2")
      assert length(rows) == 2

      assert {:ok, rows} = Reflections.list(nil)
      assert length(rows) == 3

      assert {:error, :bad_limit} = Reflections.list(0)
      assert {:error, :bad_limit} = Reflections.list(-1)
      assert {:error, :bad_limit} = Reflections.list(Reflections.max_limit() + 1)
      assert {:error, :bad_limit} = Reflections.list("two")
      assert {:error, :bad_limit} = Reflections.list([2])
    end

    test "an empty store answers, and answering is not failing" do
      # `{:ok, []}` is a fact about the store (nothing has been written yet).
      # A *failed* read is `{:error, reason}` — which the consumer turns into a
      # refusal on the wire, so a reader can never mistake "nothing" for
      # "nothing answered".
      assert {:ok, []} = Reflections.list(nil)
      assert {:ok, []} = Reflections.list(5)
    end
  end
end
