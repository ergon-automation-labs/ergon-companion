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

      assert {:ok, stored} =
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
        assert {:ok, _view} = Reflections.capture(%{"text" => text})
      end

      assert {:ok, rows} = Reflections.list(nil)
      assert Enum.map(rows, & &1["text"]) == ["third", "second", "first"]
    end

    test "an unreadable timestamp does not cost her the words" do
      assert {:ok, stored} =
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

      assert {:ok, stored} = Reflections.capture(%{"text" => String.duplicate("a", max)})
      assert stored["chars"] == max
    end

    test "the database holds the line for a writer that walks past the service" do
      # No changeset, no validation: `text` is NOT NULL, so a wordless row is
      # refused by the store itself rather than kept as a blank reflection.
      assert_raise Postgrex.Error, fn -> Repo.insert!(%Reflection{}) end
    end

    test "one reflection is read back by id" do
      assert {:ok, stored} = Reflections.capture(%{"text" => "a single line"})
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
        assert {:ok, _view} = Reflections.capture(%{"text" => text})
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
