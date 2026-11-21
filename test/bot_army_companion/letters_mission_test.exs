defmodule BotArmyCompanion.LettersMissionTest do
  @moduledoc """
  Eir writes home about the adventures the game master sends her on.

  A finished mission is read from the RPG bot (`rpg.mission.recent`, `rpg.mission.debrief`), turned
  into a prompt that holds only what her party witnessed, asked of the model through the same sealed
  path her replies use, and stored as her own letter. No database and no model here: the RPG bot, the
  soul, the model and the store are doubles, so each rule is asserted on what it was asked.
  """

  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyCompanion.Letters.Mission

  @soul %{
    "identity" => %{"name" => "Eir"},
    "character" => "A pen pal who writes back.",
    "tone" => "warm, unhurried"
  }

  @debrief %{
    "session_id" => "m1",
    "scene" => "A rooftop above the Nexus, and the contact is late.",
    "ended_at" => "2026-11-21T07:08:41Z",
    "party" => [
      %{"name" => "Eir", "bot_id" => "companion_bot"},
      %{"name" => "Mara Voss", "bot_id" => "gtd_bot"},
      %{"name" => "Kira \"Ghost\" Tanaka", "bot_id" => "llm_bot"}
    ],
    "turns" => [
      %{"round" => 1, "name" => "Eir", "action" => "persuade", "outcome" => "failure"},
      %{"round" => 1, "name" => "Mara Voss", "action" => "hack", "outcome" => "success"},
      %{
        "round" => 1,
        "name" => "Kira \"Ghost\" Tanaka",
        "action" => "persuade",
        "outcome" => "critical_failure"
      }
    ],
    "story" => ["Eir's pitch falls flat.", "Mara slices the net.", "Kira's plea is rerouted."]
  }

  describe "compose/3" do
    test "the system prompt is her soul, then what a mission letter is" do
      {system, _user} = Mission.compose(@soul, @debrief, "companion_bot")

      assert system =~ "You are Eir."
      assert system =~ "A pen pal who writes back."
      assert system =~ "not a reply"
      assert system =~ "plain prose"
      assert system =~ "Do not change an outcome"
      assert system =~ "do not add"
      assert system =~ "one small question about Abby's own day"
    end

    test "it tells her not to steer, and not to use the persuasive telling, in a letter nobody asked for" do
      {system, _} = Mission.compose(@soul, @debrief, "companion_bot")

      assert system =~ "Do not steer her toward any goal"
      assert system =~ "no persuasive techniques"
    end

    test "it says it is a game both know is play, and that she knows nothing of her companions' pasts" do
      {system, _} = Mission.compose(@soul, @debrief, "companion_bot")

      assert system =~ "play"
      assert system =~ "nothing of their pasts"
    end

    test "the user text is the record: scene, who went with her marked as you, the turns in words, the GM's lines" do
      {_system, user} = Mission.compose(@soul, @debrief, "companion_bot")

      assert user =~ "A rooftop above the Nexus, and the contact is late."
      assert user =~ "Eir (you), Mara Voss and Kira \"Ghost\" Tanaka"
      assert user =~ "Round 1: Eir (you) tried to persuade, and it did not work."
      assert user =~ "Round 1: Mara Voss tried to hack, and it worked."

      assert user =~
               "Round 1: Kira \"Ghost\" Tanaka tried to persuade, and it went disastrously wrong."

      assert user =~ "- Eir's pitch falls flat."
      assert user =~ "- Kira's plea is rerouted."
    end

    test "every outcome has its own words, and an unknown one is passed through, not hidden" do
      turn = fn outcome ->
        %{
          @debrief
          | "turns" => [
              %{"round" => 1, "name" => "Eir", "action" => "hack", "outcome" => outcome}
            ]
        }
      end

      for {outcome, words} <- [
            {"critical_success", "it went brilliantly"},
            {"success", "it worked"},
            {"failure", "it did not work"},
            {"critical_failure", "it went disastrously wrong"},
            {"stalemate", "stalemate"}
          ] do
        {_s, user} = Mission.compose(@soul, turn.(outcome), "companion_bot")
        assert user =~ words, outcome
      end
    end

    test "the record's own order is kept, and nothing is added to it" do
      {_s, user} = Mission.compose(@soul, @debrief, "companion_bot")

      assert user =~ ~r/falls flat.*slices the net.*rerouted/s
      refute user =~ "backstory"
      refute user =~ "secret"
    end

    test "a mission with no lines from the GM is still a letter, told from the turns" do
      {_s, user} = Mission.compose(@soul, Map.put(@debrief, "story", []), "companion_bot")

      assert user =~ "Round 1: Eir (you) tried to persuade"
      refute user =~ "game master said"
    end

    test "a scene that is blank is left out, not shown as empty" do
      {_s, user} = Mission.compose(@soul, Map.put(@debrief, "scene", "  "), "companion_bot")
      refute user =~ "Where it began"
    end

    test "the soul's name is hers; without one she is Eir" do
      {system, _} = Mission.compose(%{"character" => "x"}, @debrief, "companion_bot")
      assert system =~ "You are Eir."
    end
  end

  # -- write_new/1 ----------------------------------------------------------------------

  defmodule Llm do
    @moduledoc false
    def answer(system, user, opts) do
      send(Process.get(:test_pid), {:asked, system, user, opts})
      Process.get(:llm_reply, {:ok, %{text: "Dear Abby, the roof was cold. Eir", model: "m"}})
    end
  end

  defp setup_world(attrs \\ %{}) do
    Process.put(:test_pid, self())
    Process.put(:stored, [])
    Process.put(:told, MapSet.new())

    recent = %{
      "missions" => [
        %{"session_id" => "m3", "ended_at" => "2026-11-21T09:00:00Z", "turns" => 3},
        %{"session_id" => "m2", "ended_at" => "2026-11-21T08:00:00Z", "turns" => 3},
        %{"session_id" => "m1", "ended_at" => "2026-11-21T07:00:00Z", "turns" => 3}
      ]
    }

    rpg = fn
      "rpg.mission.recent", payload ->
        send(self(), {:rpg, "recent", payload})
        Map.get(attrs, :recent, {:ok, recent})

      "rpg.mission.debrief", %{"session_id" => id} ->
        send(self(), {:rpg, "debrief", id})
        Map.get(attrs, :debrief, {:ok, Map.put(@debrief, "session_id", id)})
    end

    store = fn id, text, _now ->
      Process.put(:stored, [{id, text} | Process.get(:stored)])
      Map.get(attrs, :store, {:ok, %{"id" => "letter-#{id}"}})
    end

    [
      rpg: rpg,
      soul: Map.get(attrs, :soul, fn -> {:ok, @soul} end),
      llm: Llm,
      told?: fn id -> MapSet.member?(Process.get(:told), id) end,
      store: store,
      since: "2026-11-21T06:00:00Z",
      leader: "companion_bot",
      leader?: fn -> true end,
      ready?: fn -> true end,
      now: ~U[2026-11-21 10:00:00Z]
    ]
  end

  defp stored_ids, do: Process.get(:stored) |> Enum.map(&elem(&1, 0))

  describe "write_new/1" do
    test "writes a letter for each untold mission, oldest first, so the thread reads in order" do
      assert {:ok, results} = Mission.write_new(setup_world() ++ [max_per_pass: 5])

      assert results == [{"m1", :written}, {"m2", :written}, {"m3", :written}]
      assert Enum.reverse(stored_ids()) == ["m1", "m2", "m3"]
    end

    test "asks the RPG bot for this leader's missions after the cutoff, bounded" do
      Mission.write_new(setup_world())

      assert_received {:rpg, "recent", payload}
      assert payload["leader_bot_id"] == "companion_bot"
      assert payload["since"] == "2026-11-21T06:00:00Z"
      assert payload["limit"] >= 1
    end

    test "a mission already told is not told again, and costs no model call" do
      Process.put(:told, MapSet.new(["m1", "m2", "m3"]))
      opts = setup_world()
      Process.put(:told, MapSet.new(["m1", "m2", "m3"]))

      assert {:ok, []} = Mission.write_new(opts)
      refute_received {:asked, _, _, _}
      refute_received {:rpg, "debrief", _}
    end

    test "only the missions not yet told are written" do
      opts = setup_world() ++ [max_per_pass: 5]
      Process.put(:told, MapSet.new(["m2"]))

      assert {:ok, [{"m1", :written}, {"m3", :written}]} = Mission.write_new(opts)
    end

    test "the default pace is gentle: two a pass" do
      assert {:ok, [{"m1", :written}, {"m2", :written}]} = Mission.write_new(setup_world())
    end

    test "no more than the per-pass limit are written, oldest first, so a backlog is told gently" do
      assert {:ok, [{"m1", :written}]} = Mission.write_new(setup_world() ++ [max_per_pass: 1])

      assert {:ok, [{"m1", :written}, {"m2", :written}]} =
               Mission.write_new(setup_world() ++ [max_per_pass: 2])
    end

    test "the model is asked with her soul, the record, the sealed letters options, and no hidden thinking" do
      Mission.write_new(setup_world() ++ [max_per_pass: 1])

      assert_received {:asked, system, user, opts}
      assert system =~ "You are Eir."
      assert user =~ "Round 1: Eir (you) tried to persuade"
      assert opts[:seal] == true
      assert opts[:model_type] == "uncensored"
      assert opts[:think] == false
    end

    test "what is stored is the model's own letter, trimmed" do
      Process.put(
        :llm_reply,
        {:ok, %{text: "\n  Dear Abby, the roof was cold. Eir  \n", model: "m"}}
      )

      Mission.write_new(setup_world() ++ [max_per_pass: 1])
      assert [{"m1", "Dear Abby, the roof was cold. Eir"}] = Process.get(:stored)
    end

    test "only the primary writes: a standby asks nothing and writes nothing" do
      opts = Keyword.put(setup_world(), :leader?, fn -> false end)

      assert {:ok, []} = Mission.write_new(opts)
      refute_received {:rpg, "recent", _}
      refute_received {:asked, _, _, _}
      assert stored_ids() == []
    end

    test "a node without the letters key asks nothing and writes nothing: a model call it could not store" do
      opts = Keyword.put(setup_world(), :ready?, fn -> false end)

      assert {:ok, []} = Mission.write_new(opts)
      refute_received {:rpg, "recent", _}
      refute_received {:asked, _, _, _}
    end

    test "the RPG bot not answering is an error and nothing is written" do
      opts = setup_world(%{recent: {:error, :timeout}})
      assert {:error, :rpg_unavailable} = Mission.write_new(opts)
      assert stored_ids() == []
    end

    test "an answer the RPG bot refused is an error, not an empty thread" do
      opts = setup_world(%{recent: {:ok, "nonsense"}})
      assert {:error, :rpg_unavailable} = Mission.write_new(opts)
    end

    test "no soul: nothing is asked of the model, and the mission is left for the next pass" do
      opts = setup_world(%{soul: fn -> {:error, :no_soul} end})

      assert {:error, :no_soul} = Mission.write_new(opts)
      refute_received {:asked, _, _, _}
      assert stored_ids() == []
    end

    test "a model that cannot answer writes nothing for that mission, and the others are still tried" do
      opts = setup_world() ++ [max_per_pass: 3]
      Process.put(:llm_reply, {:error, :unavailable})

      assert {:ok, results} = Mission.write_new(opts)
      assert Enum.all?(results, &match?({_, {:failed, :unavailable}}, &1))
      assert stored_ids() == []
    end

    test "an empty answer is not a letter" do
      for reply <- [{:ok, %{text: "   "}}, {:ok, %{text: nil}}, {:ok, %{}}, :weird] do
        Process.put(:llm_reply, reply)
        opts = setup_world() ++ [max_per_pass: 1]
        assert {:ok, [{"m1", {:failed, _}}]} = Mission.write_new(opts)
        assert stored_ids() == []
      end
    end

    test "a letter too long for the thread is a failure, not a truncation" do
      Process.put(
        :llm_reply,
        {:ok, %{text: String.duplicate("a", BotArmyCompanion.Letters.max_chars() + 1)}}
      )

      opts = setup_world() ++ [max_per_pass: 1]

      assert {:ok, [{"m1", {:failed, :too_long}}]} = Mission.write_new(opts)
      assert stored_ids() == []
    end

    test "a debrief the RPG bot refuses is that mission's failure, not the pass's" do
      opts = setup_world(%{debrief: {:error, :still_running}}) ++ [max_per_pass: 2]

      assert {:ok, [{"m1", {:failed, :debrief}}, {"m2", {:failed, :debrief}}]} =
               Mission.write_new(opts)

      refute_received {:asked, _, _, _}
    end

    test "a store that finds the letter already there is not a failure" do
      opts = setup_world(%{store: {:error, :exists}}) ++ [max_per_pass: 1]
      assert {:ok, [{"m1", :already}]} = Mission.write_new(opts)
    end

    test "a store that fails is that mission's failure" do
      opts = setup_world(%{store: {:error, :unavailable}}) ++ [max_per_pass: 1]
      assert {:ok, [{"m1", {:failed, :unavailable}}]} = Mission.write_new(opts)
    end

    test "a crash in the model call is a failure for that mission and does not take the pass down" do
      defmodule Crashing do
        @moduledoc false
        def answer(_s, _u, _o), do: raise("model exploded")
      end

      opts = Keyword.put(setup_world() ++ [max_per_pass: 1], :llm, Crashing)
      assert {:ok, [{"m1", {:failed, :crashed}}]} = Mission.write_new(opts)
    end

    test "with no cutoff it will not write: a backlog of old missions is never told by accident" do
      opts = Keyword.delete(setup_world(), :since)
      assert {:error, :no_cutoff} = Mission.write_new(opts)
      refute_received {:rpg, "recent", _}
    end
  end
end
