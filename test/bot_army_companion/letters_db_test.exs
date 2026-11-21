defmodule BotArmyCompanion.LettersDbTest do
  @moduledoc """
  The pen-pal thread against a live Postgres: that the words are only ever ciphertext in the
  table, that a repeat send is one letter, that a crisis letter is answered at once and no model is
  asked, that two workers cannot claim the same letter, and that several letters get one reply.

  Excluded from the default suite; run with `mix test --include integration`. `config/test.exs`
  points at the dedicated *test* database.
  """

  use ExUnit.Case, async: false

  @moduletag :stores

  alias BotArmyCompanion.{Letter, Letters, Repo, Sealed}
  alias BotArmyCompanion.Letters.Compose
  alias BotArmyCompanion.Test.PostgresHelper

  @key Base.encode64(:binary.copy(<<5>>, 32))
  @secret "my sister and I haven't spoken since June"

  @soul %{
    "identity" => %{"name" => "Eir"},
    "character" => "A pen pal who writes back.",
    "tone" => "warm"
  }

  # The model: records what it was asked (so a test can read the prompt), answers from a script.
  defmodule Llm do
    @moduledoc false
    def answer(system, user, opts) do
      send(self(), {:asked, system, user, opts})
      Process.get(:llm_reply, {:ok, %{text: "Dear Abby, I read it twice. Eir", model: "m"}})
    end
  end

  # 02:00 MST Fri 20 Nov (overnight), 11:00 MST (day), 22:00 MST Thu 19 Nov (evening).
  @overnight ~U[2026-11-20 09:00:00Z]
  @day ~U[2026-11-20 18:00:00Z]
  @evening ~U[2026-11-20 05:00:00Z]

  describe "letters (live Postgres)" do
    @describetag :integration

    setup do
      System.put_env("LETTERS_SEALED_KEYS", Jason.encode!(%{"letters1" => @key}))
      on_exit(fn -> System.delete_env("LETTERS_SEALED_KEYS") end)

      start_supervised!(Repo)
      PostgresHelper.reset_schema!(Repo)
      assert :ok = BotArmyCompanion.Release.migrate()
      :ok
    end

    defp send!(text, rid, now) do
      assert {:ok, result, state} = Letters.send_letter(text, rid, now: now)
      {result, state}
    end

    defp deliver!(ids, now \\ @day) do
      Letters.deliver(ids, soul: fn -> {:ok, @soul} end, llm: Llm, now: now)
    end

    defp status_of(id), do: Repo.get!(Letter, id).status

    test "the words are ciphertext in the table and come back whole through the thread" do
      {%{"letter" => letter}, :created} = send!(@secret, "r1", @day)

      raw = Repo.get!(Letter, letter["id"])
      refute inspect(raw.body) =~ "sister"
      assert raw.body["alg"] == "A256GCM"

      assert {:ok, [view]} = Letters.thread(now: @day)
      assert view["text"] == @secret
      assert view["author"] == "abby"
    end

    test "a body copied onto another row does not open" do
      {%{"letter" => a}, _} = send!("first", "r1", @day)
      {%{"letter" => b}, _} = send!("second", "r2", @day)

      stolen = Repo.get!(Letter, a["id"]).body
      Repo.get!(Letter, b["id"]) |> Ecto.Changeset.change(body: stolen) |> Repo.update!()

      {:ok, thread} = Letters.thread(now: @day)
      assert Enum.find(thread, &(&1["id"] == b["id"]))["text"] == nil
    end

    test "a repeat of the same request id is the first letter, not a second" do
      {first, :created} = send!("once", "same-press", @day)
      {again, :existing} = send!("once", "same-press", @day)

      assert again["letter"]["id"] == first["letter"]["id"]
      assert Repo.aggregate(Letter, :count) == 1
    end

    test "a concurrent double press makes one letter" do
      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> Letters.send_letter("tap", "race", now: @day) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.all?(results, &match?({:ok, _, _}, &1))
      assert Repo.aggregate(Letter, :count) == 1
      assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    end

    test "refusals store nothing" do
      assert {:error, :no_text} = Letters.send_letter("   ", "r", now: @day)
      assert {:error, :no_text} = Letters.send_letter(nil, "r", now: @day)

      assert {:error, {:too_long, 8000}} =
               Letters.send_letter(String.duplicate("a", 8001), "r", now: @day)

      assert {:error, :needs_request_id} = Letters.send_letter("hi", nil, now: @day)
      assert {:error, :needs_request_id} = Letters.send_letter("hi", " ", now: @day)

      System.delete_env("LETTERS_SEALED_KEYS")
      assert {:error, :sealed_key_not_configured} = Letters.send_letter("hi", "r", now: @day)
      assert Repo.aggregate(Letter, :count) == 0
    end

    test "an evening letter waits for tomorrow morning, a daytime one for a few hours" do
      {%{"letter" => evening}, _} = send!("late", "e", @evening)
      assert evening["status"] == "waiting"
      assert evening["felt"] == "tomorrow morning"
      assert Repo.get!(Letter, evening["id"]).deliver_at == ~U[2026-11-20 14:30:00.000000Z]

      {%{"letter" => day}, _} = send!("midday", "d", @day)
      assert day["felt"] == "in about 3 hours"
      assert Repo.get!(Letter, day["id"]).deliver_at == ~U[2026-11-20 21:00:00.000000Z]
    end

    test "an overnight letter says this morning" do
      {%{"letter" => letter}, _} = send!("2am", "o", @overnight)
      assert letter["felt"] == "this morning"
    end

    test "a crisis letter at 2 a.m. is answered immediately with the safety reply, and no model is asked" do
      {%{"letter" => letter, "reply" => reply}, :created} =
        send!("some days I want to die", "crisis", @overnight)

      assert letter["status"] == "answered"
      assert reply["kind"] == "safety"
      assert reply["author"] == "eir"
      assert reply["text"] == Compose.safety_reply()
      refute Map.has_key?(letter, "felt")

      # Nothing waits, so nothing is ever delivered by the model.
      assert Letters.claim_due(~U[2026-12-31 00:00:00Z]) == []
      refute_received {:asked, _, _, _}

      # A repeat of the same press returns the same pair and writes no second reply.
      {again, :existing} = send!("some days I want to die", "crisis", @overnight)
      assert again["reply"]["id"] == reply["id"]
      assert Repo.aggregate(Letter, :count) == 2
    end

    test "claim_due takes only what is due, once" do
      {%{"letter" => due}, _} = send!("due", "a", @day)
      # 19:00 MST on the 20th: an evening letter, due 07:30 on the 21st, after the daytime one.
      {%{"letter" => later}, _} = send!("later", "b", ~U[2026-11-21 02:00:00Z])

      assert Letters.claim_due(~U[2026-11-20 20:00:00Z]) == []
      assert Letters.claim_due(~U[2026-11-20 21:00:01Z]) == [due["id"]]
      assert Letters.claim_due(~U[2026-11-20 21:00:01Z]) == []
      assert status_of(due["id"]) == "writing"
      assert status_of(later["id"]) == "waiting"
    end

    test "two workers racing for the same letters split them and never double-claim" do
      for n <- 1..12, do: send!("letter #{n}", "k#{n}", @day)
      after_due = ~U[2026-11-20 22:00:00Z]

      claims =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Letters.claim_due(after_due) end) end)
        |> Enum.flat_map(&Task.await/1)

      assert length(claims) == 12
      assert length(Enum.uniq(claims)) == 12
    end

    test "a claimed letter a worker abandoned goes back to waiting, and only after a model's patience" do
      {%{"letter" => l}, _} = send!("x", "a", @day)
      [_] = Letters.claim_due(~U[2026-11-20 21:00:01Z])

      assert Letters.reclaim_stale(~U[2026-11-20 21:05:00Z]) == 0
      assert status_of(l["id"]) == "writing"
      assert Letters.reclaim_stale(~U[2026-11-20 21:30:00Z]) == 1
      assert status_of(l["id"]) == "waiting"
    end

    test "several waiting letters get ONE reply, which sees all of them, in order" do
      for {t, n} <- [{"first", 1}, {"second", 2}, {"third", 3}] do
        send!(t, "b#{n}", DateTime.add(@evening, n * 60))
      end

      ids = Letters.claim_due(~U[2026-11-20 15:00:00Z])
      assert length(ids) == 3

      assert {:ok, reply} = deliver!(ids, ~U[2026-11-20 15:00:00Z])
      assert reply["author"] == "eir"

      assert_received {:asked, system, user, opts}
      assert system =~ "You are Eir."
      assert user =~ "first\n\n---\n\nsecond\n\n---\n\nthird"
      assert user =~ "answering together now"
      assert opts[:seal] == true

      assert Repo.aggregate(from_eir(), :count) == 1
      assert Enum.all?(ids, &(status_of(&1) == "answered"))

      assert Repo.get!(Letter, reply["id"]).reply_to_id in ids
    end

    test "the model is always asked sealed, whatever the configuration says" do
      Application.put_env(:bot_army_companion, :letters, llm_opts: [seal: false, max_tokens: 50])
      on_exit(fn -> Application.delete_env(:bot_army_companion, :letters) end)

      opts = Letters.llm_opts()
      assert opts[:seal] == true
      assert opts[:max_tokens] == 50
      assert opts[:uncensored_tier] == "light"
    end

    test "a letter that arrives after the claim waits for its own reply" do
      {%{"letter" => first}, _} = send!("first", "a", @day)
      [id] = Letters.claim_due(~U[2026-11-20 21:00:01Z])
      {%{"letter" => second}, _} = send!("second", "b", ~U[2026-11-20 21:01:00Z])
      assert id == first["id"]

      assert {:ok, _} = deliver!([id], ~U[2026-11-20 21:02:00Z])
      assert_received {:asked, _s, user, _}
      refute user =~ "second"
      assert status_of(id) == "answered"
      assert status_of(second["id"]) == "waiting"
    end

    test "no soul: nothing is asked, nothing is written, the letters are failed and not lost" do
      {%{"letter" => l}, _} = send!("hello", "a", @day)
      [id] = Letters.claim_due(~U[2026-11-20 21:00:01Z])

      assert {:error, :no_soul} =
               Letters.deliver([id], soul: fn -> {:error, :no_soul} end, llm: Llm, now: @day)

      refute_received {:asked, _, _, _}
      assert status_of(l["id"]) == "failed"
      assert Repo.aggregate(from_eir(), :count) == 0
    end

    test "a failed letter is answered together with the next, so nothing is lost" do
      {%{"letter" => old}, _} = send!("the one that failed", "a", @day)
      [id] = Letters.claim_due(~U[2026-11-20 21:00:01Z])
      Process.put(:llm_reply, {:error, :timeout})
      assert {:error, :timeout} = deliver!([id])
      assert status_of(old["id"]) == "failed"
      # The failed attempt asked the model once; clear that so the next read is the retry's.
      assert_received {:asked, _, _, _}

      Process.put(:llm_reply, {:ok, %{text: "Dear Abby. Eir", model: "m"}})
      {%{"letter" => newer}, _} = send!("a new one", "b", ~U[2026-11-20 22:00:00Z])
      [id2] = Letters.claim_due(~U[2026-11-21 14:31:00Z])
      assert id2 == newer["id"]

      assert {:ok, _} = deliver!([id2], ~U[2026-11-21 14:31:00Z])
      assert_received {:asked, _s, user, _}
      assert user =~ "the one that failed\n\n---\n\na new one"
      assert status_of(old["id"]) == "answered"
      assert status_of(newer["id"]) == "answered"
    end

    test "a model that cannot answer fails the letter and stores no reply" do
      for reply <- [{:error, :unavailable}, {:ok, %{text: "  ", model: "m"}}, :surprise] do
        Process.put(:llm_reply, reply)
        {%{"letter" => l}, _} = send!("hello", "r#{System.unique_integer([:positive])}", @day)
        ids = Letters.claim_due(~U[2026-12-31 00:00:00Z])
        assert {:error, _} = deliver!(ids)
        assert status_of(l["id"]) == "failed"
      end

      assert Repo.aggregate(from_eir(), :count) == 0
    end

    test "a crash in the model is contained and its message is never logged" do
      defmodule Boom do
        @moduledoc false
        def answer(_s, user, _o), do: raise("provider choked on: " <> user)
      end

      {%{"letter" => l}, _} = send!(@secret, "boom", @day)
      [id] = Letters.claim_due(~U[2026-11-20 21:00:01Z])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :crashed} =
                   Letters.deliver([id], soul: fn -> {:ok, @soul} end, llm: Boom, now: @day)
        end)

      refute log =~ "sister"
      assert status_of(l["id"]) == "failed"
    end

    test "the letter after a safety reply gets the gentle check-in" do
      {_, :created} = send!("some days I want to die", "c", @overnight)
      send!("I'm okay today", "n", @day)
      ids = Letters.claim_due(~U[2026-11-20 21:00:01Z])

      assert {:ok, _} = deliver!(ids)
      assert_received {:asked, system, user, _}
      assert system =~ "how she is doing now"
      assert user =~ "You wrote:"
    end

    test "the clock delivers what is due, leaves the rest, and goes quiet" do
      alias BotArmyCompanion.Letters.Worker

      {%{"letter" => due}, _} = send!("due", "a", @day)
      {%{"letter" => later}, _} = send!("later", "b", ~U[2026-11-21 02:00:00Z])
      opts = [soul: fn -> {:ok, @soul} end, llm: Llm]

      assert :idle = Worker.run_once([now: ~U[2026-11-20 20:00:00Z]] ++ opts)
      assert {:delivered, reply} = Worker.run_once([now: ~U[2026-11-20 21:00:01Z]] ++ opts)
      assert reply["author"] == "eir"
      assert status_of(due["id"]) == "answered"
      assert status_of(later["id"]) == "waiting"
      assert :idle = Worker.run_once([now: ~U[2026-11-20 21:00:02Z]] ++ opts)
    end

    test "a claimed letter that will not open stops delivery rather than answering nothing" do
      {%{"letter" => l}, _} = send!("hello", "a", @day)
      Repo.get!(Letter, l["id"]) |> Ecto.Changeset.change(body: %{"junk" => 1}) |> Repo.update!()
      [id] = Letters.claim_due(~U[2026-11-20 21:00:01Z])

      assert {:error, :unreadable} = deliver!([id])
      refute_received {:asked, _, _, _}
    end

    test "a store that is down is an answer, not a crash" do
      stop_supervised!(Repo)
      assert {:error, :store_unavailable} = Letters.send_letter("hi", "r", now: @day)
      assert {:error, :store_unavailable} = Letters.thread(now: @day)
    end
  end

  # Every one of Eir's letters.
  defp from_eir do
    import Ecto.Query, only: [from: 2]
    from(l in Letter, where: l.author == "eir")
  end

  test "sealing at rest uses the letters channel's key and a purpose of its own" do
    assert Sealed.letter_at_rest_aad("abc") == "companion.letter.v1|abc"
    refute Sealed.letter_at_rest_aad("abc") == Sealed.aad(:request, "abc")
  end
end
