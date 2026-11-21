defmodule BotArmyCompanion.LettersMissionDbTest do
  @moduledoc """
  A mission letter against live Postgres: sealed at rest like every letter, hers, told once, shown in
  the thread, and in the history Eir sees when Abby writes back.

  Excluded from the default suite; run with `mix test --include integration`. `config/test.exs`
  points at a dedicated *test* database.
  """

  use ExUnit.Case, async: false

  @moduletag :stores

  import Ecto.Query

  alias BotArmyCompanion.{Letter, Letters, Repo}
  alias BotArmyCompanion.Letters.Mission
  alias BotArmyCompanion.Test.PostgresHelper

  @key Base.encode64(:binary.copy(<<6>>, 32))
  @text "Abby, the roof was cold and the contact never came. Eir"
  @now ~U[2026-11-21 18:00:00Z]

  @soul %{"identity" => %{"name" => "Eir"}, "character" => "A pen pal.", "tone" => "warm"}

  @good_letter String.trim("""
               Abby,

               The roof was cold and the contact never came. I talked first, because I always do, and it fell flat. Then Mara tried the net and slipped, and Kira's plea got rerouted into a wall of firewall. Three of us, three misses.

               I liked it anyway. Nobody on that roof stopped trying, and I would take Mara and Kira with me again.

               What was the best part of your day?

               Eir
               """)

  defmodule Llm do
    @moduledoc false
    # The writer's draft and the editor's grade, told apart by the system prompt.
    def answer(system, user, _opts) do
      send(Process.get(:test_pid), {:asked, system, user})

      if String.contains?(system, "You are an editor") do
        {:ok,
         %{
           text:
             ~s({"faithful": true, "invented": [], "voice": 4, "excitement": 4, "clarity": 4, "notes": ""})
         }}
      else
        {:ok, %{text: Process.get(:letter), model: "m"}}
      end
    end
  end

  describe "a mission letter (live Postgres)" do
    @describetag :integration

    setup do
      Process.put(:test_pid, self())
      Process.put(:letter, @good_letter)
      System.put_env("LETTERS_SEALED_KEYS", Jason.encode!(%{"letters1" => @key}))
      on_exit(fn -> System.delete_env("LETTERS_SEALED_KEYS") end)

      start_supervised!(Repo)
      PostgresHelper.reset_schema!(Repo)
      assert :ok = BotArmyCompanion.Release.migrate()
      :ok
    end

    test "is hers, with no reply_to, under the mission's key, and the words are ciphertext in the table" do
      assert {:ok, view} = Mission.store_letter("m1", @text, @now)
      assert view["author"] == "eir"

      raw = Repo.get!(Letter, view["id"])
      assert raw.author == "eir"
      assert raw.kind == "normal"
      assert raw.status == "none"
      assert raw.reply_to_id == nil
      assert raw.dedupe_key == "mission:m1"
      assert raw.body["alg"] == "A256GCM"
      refute inspect(raw.body) =~ "contact never came"
    end

    test "comes back whole through the thread" do
      {:ok, _} = Mission.store_letter("m1", @text, @now)

      assert {:ok, [view]} = Letters.thread(now: @now)
      assert view["author"] == "eir"
      assert view["text"] == @text
    end

    test "a mission is told once: the second letter for it is refused, and there is one row" do
      assert {:ok, _} = Mission.store_letter("m1", @text, @now)
      assert {:error, :exists} = Mission.store_letter("m1", "a second telling", @now)

      assert Repo.aggregate(Letter, :count) == 1
      assert Mission.told?("m1")
      refute Mission.told?("m2")
    end

    test "two passes racing for one mission leave one letter" do
      results =
        for _ <- 1..4 do
          Task.async(fn -> Mission.store_letter("m1", @text, @now) end)
        end
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :exists})) == 3
      assert Repo.aggregate(Letter, :count) == 1
    end

    test "a letter that cannot be sealed (no key) is refused, and nothing is stored" do
      System.delete_env("LETTERS_SEALED_KEYS")
      assert {:error, _} = Mission.store_letter("m1", @text, @now)
      assert Repo.aggregate(Letter, :count) == 0
    end

    test "when Abby writes back, the model is shown the mission letter as one Eir wrote" do
      {:ok, _} = Mission.store_letter("m1", @text, @now)

      assert {:ok, %{"letter" => letter}, :created} =
               Letters.send_letter("That sounds like a night. What happened next?", "r1",
                 now: @now
               )

      assert {:ok, _} =
               Letters.deliver([letter["id"]], soul: fn -> {:ok, @soul} end, llm: Llm, now: @now)

      assert_received {:asked, _system, user}
      assert user =~ "You wrote:"
      assert user =~ "the contact never came"
      assert user =~ "What happened next?"
    end

    test "the writer's whole pass, against the real store, with the RPG bot and the model as doubles" do
      rpg = fn
        "rpg.mission.recent", _ ->
          {:ok,
           %{
             "missions" => [
               %{"session_id" => "m1", "ended_at" => "2026-11-21T07:00:00Z", "turns" => 1}
             ]
           }}

        "rpg.mission.debrief", _ ->
          {:ok,
           %{
             "scene" => "A roof.",
             "party" => [
               %{"name" => "Eir", "bot_id" => "companion_bot"},
               %{"name" => "Mara Voss", "bot_id" => "gtd_bot"},
               %{"name" => "Kira \"Ghost\" Tanaka", "bot_id" => "llm_bot"}
             ],
             "turns" => [
               %{"round" => 1, "name" => "Eir", "action" => "persuade", "outcome" => "success"}
             ],
             "story" => ["Eir talks her way in."]
           }}
      end

      opts = [
        rpg: rpg,
        soul: fn -> {:ok, @soul} end,
        llm: Llm,
        leader?: fn -> true end,
        ready?: fn -> true end,
        since: "2026-11-21T00:00:00Z",
        now: @now
      ]

      assert {:ok, [{"m1", :written}]} = Mission.write_new(opts)
      assert {:ok, []} = Mission.write_new(opts)

      assert {:ok, [view]} = Letters.thread(now: @now)
      assert view["author"] == "eir"
      assert view["text"] == @good_letter

      assert Repo.aggregate(from(l in Letter, where: like(l.dedupe_key, "mission:%")), :count) ==
               1
    end

    test "a letter that is not good enough is held: nothing reaches the table" do
      Process.put(:letter, "**Hi.** Short.")

      rpg = fn
        "rpg.mission.recent", _ ->
          {:ok,
           %{
             "missions" => [
               %{"session_id" => "m1", "ended_at" => "2026-11-21T07:00:00Z", "turns" => 1}
             ]
           }}

        "rpg.mission.debrief", _ ->
          {:ok,
           %{
             "scene" => "A roof.",
             "party" => [%{"name" => "Eir", "bot_id" => "companion_bot"}],
             "turns" => [
               %{"round" => 1, "name" => "Eir", "action" => "persuade", "outcome" => "success"}
             ],
             "story" => []
           }}
      end

      opts = [
        rpg: rpg,
        soul: fn -> {:ok, @soul} end,
        llm: Llm,
        leader?: fn -> true end,
        ready?: fn -> true end,
        since: "2026-11-21T00:00:00Z",
        now: @now
      ]

      assert {:ok, [{"m1", {:failed, :not_good_enough}}]} = Mission.write_new(opts)
      assert Repo.aggregate(Letter, :count) == 0
      refute Mission.told?("m1")
    end
  end
end
