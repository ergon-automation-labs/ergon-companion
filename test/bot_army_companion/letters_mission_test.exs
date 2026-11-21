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

  @good_letter String.trim("""
               Abby,

               The roof was cold and the contact never came. I talked first, because I always do, and it fell flat. Then Mara tried the net and slipped, and Kira's plea got rerouted into a wall of firewall. Three of us, three misses.

               I liked it anyway. Nobody on that roof stopped trying, and I would take Mara and Kira with me again.

               What was the best part of your day?

               Eir
               """)

  defmodule Llm do
    @moduledoc false
    # Two kinds of call, told apart by the system prompt: the drafter (and the rewriter) and the
    # editor. Each answers from a script in the process dictionary: a list is consumed, its last
    # element repeating, so a test says what happens first and what happens after.
    def answer(system, user, opts) do
      pid = Process.get(:test_pid)

      if String.contains?(system, "You are an editor") do
        send(pid, {:graded, system, user, opts})

        next(
          :grades,
          {:ok,
           %{
             text:
               ~s({"faithful": true, "invented": [], "voice": 4, "excitement": 4, "clarity": 4, "notes": ""})
           }}
        )
      else
        send(pid, {:asked, system, user, opts})

        next(
          :drafts,
          Process.get(:llm_reply, {:ok, %{text: Process.get(:good_letter), model: "m"}})
        )
      end
    end

    defp next(key, default) do
      case Process.get(key) do
        [last] -> last
        [head | rest] -> Process.put(key, rest) && head
        _ -> default
      end
    end
  end

  defp setup_world(attrs \\ %{}) do
    Process.put(:test_pid, self())
    Process.put(:good_letter, @good_letter)
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
      now: ~U[2026-11-22 00:00:00Z]
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
      Process.put(:llm_reply, {:ok, %{text: "\n  " <> @good_letter <> "  \n", model: "m"}})
      Mission.write_new(setup_world() ++ [max_per_pass: 1])
      assert [{"m1", text}] = Process.get(:stored)
      assert text == @good_letter
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

  describe "the grader, before a letter is stored" do
    defp bad_draft, do: String.replace(@good_letter, "roof was cold", "**roof** was cold")

    defp grade(overrides \\ %{}) do
      body =
        Map.merge(
          %{
            "faithful" => true,
            "invented" => [],
            "voice" => 4,
            "excitement" => 4,
            "clarity" => 4,
            "notes" => ""
          },
          overrides
        )

      {:ok, %{text: Jason.encode!(body)}}
    end

    defp calls(tag) do
      Stream.repeatedly(fn ->
        receive do
          m when elem(m, 0) == tag -> m
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
    end

    test "a clean letter with a good grade is stored after one draft and one grade" do
      assert {:ok, [{"m1", :written}]} = Mission.write_new(setup_world() ++ [max_per_pass: 1])

      assert length(calls(:asked)) == 1
      assert length(calls(:graded)) == 1
      assert [{"m1", @good_letter}] = Process.get(:stored)
    end

    test "the editor is shown the letter that would be sent, with her soul and the record" do
      Mission.write_new(setup_world() ++ [max_per_pass: 1])

      assert_received {:graded, system, user, opts}
      assert system =~ "A pen pal who writes back."
      assert user =~ "The roof was cold and the contact never came."
      assert user =~ "Round 1: Eir (you) tried to persuade"
      assert opts[:seal] == true
      assert opts[:think] == false
    end

    test "a draft that breaks a rule is rewritten without troubling the editor, and the rewrite is what is stored" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:drafts, [{:ok, %{text: bad_draft()}}, {:ok, %{text: @good_letter}}])

      assert {:ok, [{"m1", :written}]} = Mission.write_new(opts)

      assert [{:asked, _, first_user, _}, {:asked, _, rewrite_user, _}] = calls(:asked)
      refute first_user =~ "Your first draft"
      assert rewrite_user =~ "Your first draft:"
      assert rewrite_user =~ "**roof** was cold"
      assert rewrite_user =~ "Write plain prose"
      assert rewrite_user =~ "The mission you were sent on."

      assert length(calls(:graded)) == 1
      assert [{"m1", @good_letter}] = Process.get(:stored)
    end

    test "a letter the editor finds invented is rewritten, told what to remove" do
      opts = setup_world() ++ [max_per_pass: 1]

      Process.put(:grades, [
        grade(%{"faithful" => false, "invented" => ["a dragon over the roof"]}),
        grade()
      ])

      assert {:ok, [{"m1", :written}]} = Mission.write_new(opts)

      assert [_, {:asked, _, rewrite_user, _}] = calls(:asked)
      assert rewrite_user =~ "a dragon over the roof"
      assert rewrite_user =~ "Remove them"
      assert length(calls(:graded)) == 2
    end

    test "a weak score is rewritten with the editor's own notes" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:grades, [grade(%{"excitement" => 2, "notes" => "Open on the cold."}), grade()])

      assert {:ok, [{"m1", :written}]} = Mission.write_new(opts)
      assert [_, {:asked, _, rewrite_user, _}] = calls(:asked)
      assert rewrite_user =~ "excitement"
      assert rewrite_user =~ "Open on the cold."
    end

    test "the bar is configurable" do
      opts = setup_world() ++ [max_per_pass: 1, min_score: 5]
      assert {:ok, [{"m1", {:failed, :not_good_enough}}]} = Mission.write_new(opts)
      assert Process.get(:stored) == []
    end

    test "a letter that never gets good enough is held, after a bounded number of rewrites" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:drafts, [{:ok, %{text: bad_draft()}}])

      assert {:ok, [{"m1", {:failed, :not_good_enough}}]} = Mission.write_new(opts)

      # the draft and two rewrites, never more
      assert length(calls(:asked)) == 3
      assert Process.get(:stored) == []
    end

    test "the number of rewrites is configurable, and zero holds a letter that fails once" do
      opts = setup_world() ++ [max_per_pass: 1, max_revisions: 0]
      Process.put(:drafts, [{:ok, %{text: bad_draft()}}])

      assert {:ok, [{"m1", {:failed, :not_good_enough}}]} = Mission.write_new(opts)
      assert length(calls(:asked)) == 1
    end

    test "an editor that cannot be read twice in a row holds the letter: no grade, no send" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:grades, [{:ok, %{text: "I think it is nice!"}}])

      assert {:ok, [{"m1", {:failed, :ungradable}}]} = Mission.write_new(opts)
      assert length(calls(:graded)) == 2
      assert Process.get(:stored) == []
    end

    test "an editor that is unreadable once and fine the second time is fine" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:grades, [{:ok, %{text: "hm"}}, grade()])

      assert {:ok, [{"m1", :written}]} = Mission.write_new(opts)
      assert length(calls(:graded)) == 2
    end

    test "an editor that cannot answer holds the letter, and is a failure of the model, not of the letter" do
      opts = setup_world() ++ [max_per_pass: 1]
      Process.put(:grades, [{:error, :unavailable}])

      assert {:ok, [{"m1", {:failed, :unavailable}}]} = Mission.write_new(opts)
      assert Process.get(:stored) == []
    end

    test "the editor may be a stronger tier than the writer, by configuration" do
      Mission.write_new(setup_world() ++ [max_per_pass: 1, grader_tier: "heavy"])

      assert_received {:asked, _, _, draft_opts}
      assert_received {:graded, _, _, grade_opts}
      assert draft_opts[:uncensored_tier] == "light"
      assert grade_opts[:uncensored_tier] == "heavy"
    end

    test "a rewrite that comes back empty ends that mission's attempt, not the pass" do
      opts = setup_world() ++ [max_per_pass: 2]

      Process.put(:drafts, [
        {:ok, %{text: bad_draft()}},
        {:ok, %{text: "  "}},
        {:ok, %{text: @good_letter}}
      ])

      assert {:ok, [{"m1", {:failed, :empty_answer}}, {"m2", :written}]} = Mission.write_new(opts)
    end

    test "nothing of a letter, the record or the editor's words reaches the log" do
      Process.put(:drafts, [{:ok, %{text: bad_draft()}}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Mission.write_new(setup_world() ++ [max_per_pass: 1, max_revisions: 0])
        end)

      Process.put(:drafts, [{:ok, %{text: @good_letter}}])

      Process.put(:grades, [
        grade(%{"faithful" => false, "invented" => ["a SECRET-DRAGON"], "notes" => "SECRET-NOTE"})
      ])

      log2 =
        ExUnit.CaptureLog.capture_log(fn ->
          Mission.write_new(setup_world() ++ [max_per_pass: 1, max_revisions: 0])
        end)

      for text <- [log, log2] do
        refute text =~ "SECRET"
        refute text =~ "roof"
        refute text =~ "Mara"
      end

      assert log =~ "not good enough"
      assert log =~ "markdown"
    end
  end

  describe "the pen pal's timing: a mission letter arrives when a letter would" do
    defp ended(opts, at) do
      recent = %{"missions" => [%{"session_id" => "m1", "ended_at" => at, "turns" => 3}]}

      Keyword.put(opts, :rpg, fn
        "rpg.mission.recent", _ -> {:ok, recent}
        "rpg.mission.debrief", _ -> {:ok, @debrief}
      end)
    end

    # 2026-11-21 07:08Z is 00:08 in Denver: overnight, so it arrives at 07:30 Denver, 14:30Z.
    test "an overnight mission waits for the morning" do
      opts = setup_world() |> ended("2026-11-21T07:08:41Z")

      assert {:ok, []} = Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 14:29:00Z]))
      refute_received {:asked, _, _, _}

      assert {:ok, [{"m1", :written}]} =
               Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 14:30:00Z]))
    end

    # 2026-11-21 18:00Z is 11:00 in Denver: daytime, so a few hours later.
    test "a daytime mission waits a few hours" do
      opts = setup_world() |> ended("2026-11-21T18:00:00Z")

      assert {:ok, []} = Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 20:59:00Z]))

      assert {:ok, [{"m1", :written}]} =
               Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 21:00:00Z]))
    end

    test "a mission that is not due asks nothing of the model and fetches no debrief" do
      opts = setup_world() |> ended("2026-11-21T18:00:00Z")
      assert {:ok, []} = Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 18:00:01Z]))

      refute_received {:asked, _, _, _}
      refute_received {:graded, _, _, _}
      refute_received {:rpg, "debrief", _}
    end

    test "a mission with no readable end time is not told" do
      for bad <- [nil, "", "yesterday", 5] do
        opts = setup_world() |> ended(bad)
        assert {:ok, []} = Mission.write_new(opts)
      end
    end

    test "what is due goes first even when a later one is not due yet" do
      recent = %{
        "missions" => [
          %{"session_id" => "late", "ended_at" => "2026-11-21T20:00:00Z", "turns" => 3},
          %{"session_id" => "early", "ended_at" => "2026-11-21T07:00:00Z", "turns" => 3}
        ]
      }

      opts =
        Keyword.put(setup_world(), :rpg, fn
          "rpg.mission.recent", _ -> {:ok, recent}
          "rpg.mission.debrief", _ -> {:ok, @debrief}
        end)

      assert {:ok, [{"early", :written}]} =
               Mission.write_new(Keyword.put(opts, :now, ~U[2026-11-21 15:00:00Z]))
    end
  end

  describe "skip" do
    test "a mission named to be skipped is not written, and costs nothing" do
      assert {:ok, [{"m2", :written}]} =
               Mission.write_new(setup_world() ++ [max_per_pass: 1, skip: ["m1"]])
    end
  end
end
