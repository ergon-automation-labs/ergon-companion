defmodule BotArmyCompanion.ReflectionAdventureTest do
  @moduledoc """
  The adventure log a reflection reads — without a broker and without a model.

  These are decisions, not plumbing: which window counts as the table, who is
  said to be at it, and what the log says when nobody is. The point of the
  module is that the three nothings are said differently — no window has been
  opened (a fact), a window that could not be read (a refusal), and an empty
  table (a fact, and not a missing one). The window reader is injected as a
  function, so nothing here opens a connection.
  """

  use ExUnit.Case, async: true

  @moduletag :handlers

  alias BotArmyCompanion.Handlers.ReflectionHandler
  alias BotArmyCompanion.Thoughts

  @active_id "aaaaaaaa-1111-2222-3333-444444444444"
  @ended_id "bbbbbbbb-1111-2222-3333-444444444444"

  defp sessions_reply(sessions), do: {:ok, %{"data" => %{"sessions" => sessions}}}

  defp window_reply(facts, party \\ %{}) do
    {:ok, %{"data" => %{"scene_facts" => facts, "party" => party}}}
  end

  defp session(attrs) do
    Map.merge(
      %{
        "id" => @active_id,
        "status" => "active",
        "scene_description" => "the flooded gate",
        "updated_at" => "2026-10-01T09:00:00"
      },
      attrs
    )
  end

  defp read_window(reply), do: fn _body -> reply end

  describe "the live log's wiring" do
    test "a list that answered with no windows is a fact, not a refusal" do
      assert ReflectionHandler.adventure_log(fn -> sessions_reply([]) end) ==
               "Adventures: no window has been opened yet"
    end

    test "a session read that failed is a refusal, not an empty table" do
      assert ReflectionHandler.adventure_log(fn -> {:error, :timeout} end) ==
               "Adventures: unavailable"
    end

    test "a reader that raises does not take the reflection down with it" do
      assert ReflectionHandler.adventure_log(fn -> raise "dead broker" end) ==
               "Adventures: unavailable"
    end
  end

  describe "the window it reflects on" do
    test "no window at all is a fact, not an unavailable read" do
      log = ReflectionHandler.adventure_log(sessions_reply([]), read_window(window_reply([])))

      assert log == "Adventures: no window has been opened yet"
    end

    test "a session list that could not be read is a refusal" do
      assert ReflectionHandler.adventure_log({:error, :timeout}, read_window(window_reply([]))) ==
               "Adventures: unavailable"
    end

    test "the open window wins over one that was touched more recently" do
      sessions = [
        session(%{"id" => @ended_id, "status" => "ended", "updated_at" => "2026-10-01T12:00:00"}),
        session(%{"id" => @active_id, "status" => "active", "updated_at" => "2026-09-01T09:00:00"})
      ]

      reader = fn body ->
        send(self(), {:asked, body})
        window_reply(["a turn"])
      end

      assert ReflectionHandler.adventure_log(sessions_reply(sessions), reader) =~
               "1 turns at the table"

      assert_received {:asked, %{"session_id" => @active_id}}
    end

    test "with no window open, the one touched last is the table" do
      sessions = [
        session(%{"id" => @ended_id, "status" => "ended", "updated_at" => "2026-10-01T12:00:00"}),
        session(%{"id" => @active_id, "status" => "ended", "updated_at" => "2026-09-01T09:00:00"})
      ]

      reader = fn body ->
        send(self(), {:asked, body})
        window_reply(["a turn"])
      end

      ReflectionHandler.adventure_log(sessions_reply(sessions), reader)
      assert_received {:asked, %{"session_id" => @ended_id}}
    end
  end

  describe "the table" do
    test "names the scene, the status, the roster and the newest turns" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(
            window_reply(["the gate gives way", "she forces it"], %{
              "members" => [%{"name" => "The Lorekeeper"}, %{"name" => "The Bard"}]
            })
          )
        )

      assert log =~ ~s(Adventures: "the flooded gate", active, 2 turns at the table)
      assert log =~ "She walks with The Lorekeeper, The Bard."
      assert log =~ "Recently at the table:"
      assert log =~ "• the gate gives way"
      assert log =~ "• she forces it"
    end

    test "an empty table is a fact, and says so" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([]))
        )

      assert log =~ "0 turns at the table"
      assert log =~ "Nothing has been written at the table yet."
    end

    test "keeps the newest five turns and drops the rest" do
      facts = Enum.map(1..7, &"turn-#{&1}")

      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply(facts))
        )

      assert log =~ "• turn-1"
      assert log =~ "• turn-5"
      refute log =~ "turn-6"
      refute log =~ "turn-7"
    end

    test "trims a turn that would otherwise be an essay" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([String.duplicate("x", 400)]))
        )

      assert log =~ String.duplicate("x", 300)
      refute log =~ String.duplicate("x", 301)
    end

    test "an unreadable window says the turns are unreported rather than absent" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window({:error, :timeout})
        )

      assert log =~ "the window could not be read, so its turns are unreported"
      assert log =~ "The table's turns could not be read."
      refute log =~ "Nothing has been written at the table yet."
    end

    test "a window answer without facts is unreported, not empty" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window({:ok, %{"data" => %{}}})
        )

      assert log =~ "an unreported number of turns at the table"
      assert log =~ "The table's turns were not in the answer."
    end
  end

  describe "the roster" do
    test "a party with no members is a fact: she walks with no one" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([], %{"members" => []}))
        )

      assert log =~ "She walks with no one yet."
    end

    test "an answered-but-empty party is the same fact as an empty roster" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([], %{}))
        )

      assert log =~ "She walks with no one yet."
    end

    test "an unreadable roster is a refusal, never an empty party" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([], nil))
        )

      assert log =~ "The roster could not be read."
      refute log =~ "She walks with no one yet."
    end

    test "members the roster does not name are counted rather than dropped" do
      log =
        ReflectionHandler.adventure_log(
          sessions_reply([session(%{})]),
          read_window(window_reply([], %{"members" => [%{}, %{}]}))
        )

      assert log =~ "She walks with 2 companions the roster does not name."
    end
  end

  describe "the angle" do
    test "angle 11 asks about the party's adventures and carries no hardcoded date" do
      thought = Enum.find(Thoughts.default_thoughts(), &(&1.angle == 11))

      assert thought, "the party angle is not in the seed list"
      assert thought.active
      assert "rpg" in thought.tags

      assert thought.query =~ "party"

      refute thought.query =~
               ~r/\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b/i
    end
  end
end
