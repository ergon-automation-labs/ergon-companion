defmodule BotArmyCompanion.PartyNarratorTest do
  @moduledoc """
  The far end of rpg's ask: what the companion narrates, and what it refuses to.

  rpg hands a turn to the party's *narrator* — a role one member holds — and writes no
  words of its own. The words are written here, as a scene fact signed with this bot's
  name, and they are the only thing that makes the window's pending reading flip.

  The model is a Mox mock and the broker is a scripted stub, so these tests are about the
  decisions: who is answered, what the model is shown, what is written, and what is
  claimed when a step does not come back.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias BotArmyCompanion.PartyNarrator

  setup :verify_on_exit!

  defmodule ScriptedPublisher do
    @moduledoc false

    # Answers come from the application environment, keyed by subject, so a test reads as
    # a list of replies rather than as a mock. Each call is reported to the caller, which
    # for these tests is the process running the narration.
    def request(subject, payload, _opts) do
      send(self(), {:request, subject, payload})

      :bot_army_companion
      |> Application.get_env(:answers, %{})
      |> Map.get(subject, {:error, :no_script})
    end

    def publish(subject, payload, opts), do: request(subject, payload, opts)
  end

  defmodule RaisingPublisher do
    @moduledoc false
    def request(_subject, _payload, _opts), do: raise("the broker is gone")
    def publish(_subject, _payload, _opts), do: raise("the broker is gone")
  end

  @session "20572659-53c2-417e-b67b-fc315d7ee38b"
  @tenant "00000000-0000-0000-0000-000000000001"
  @context "rpg.session.gather_context"
  @add "rpg.scene.fact.add"

  setup do
    original = Application.get_env(:bot_army_companion, :nats_publisher)
    original_bot_id = Application.get_env(:bot_army_companion, :bot_id)

    on_exit(fn ->
      if original do
        Application.put_env(:bot_army_companion, :nats_publisher, original)
      else
        Application.delete_env(:bot_army_companion, :nats_publisher)
      end

      if original_bot_id do
        Application.put_env(:bot_army_companion, :bot_id, original_bot_id)
      else
        Application.delete_env(:bot_army_companion, :bot_id)
      end

      Application.delete_env(:bot_army_companion, :answers)
    end)

    Application.put_env(:bot_army_companion, :nats_publisher, __MODULE__.ScriptedPublisher)
    Application.put_env(:bot_army_companion, :bot_id, "companion_bot")
    :ok
  end

  # --- the ask ------------------------------------------------------------------

  defp ask(overrides \\ %{}) do
    Map.merge(
      %{
        "event" => "rpg.narration.your_turn",
        "event_id" => "11111111-1111-4111-8111-111111111111",
        "schema_version" => "1.0",
        "timestamp" => "2026-09-30T12:00:00Z",
        "source" => "bot_army_rpg",
        "source_node" => "nonode@nohost",
        "triggered_by" => "rpg.bot",
        "tenant_id" => @tenant,
        "payload" => %{
          "session_id" => @session,
          "character_id" => "c-narrator",
          "bot_id" => "companion_bot",
          "scene_description" => "probe",
          "round" => 2,
          "actor" => %{"character_id" => "c-hero", "name" => "Mira", "bot_id" => "gtd_bot"},
          "action" => %{"description" => "the lock is picked", "action_type" => "skill"},
          "resolution" => %{"outcome" => "success", "total" => 17, "dc" => 12}
        }
      },
      overrides
    )
  end

  defp window(turns, overrides \\ %{}) do
    Map.merge(
      %{
        "ok" => true,
        "data" =>
          Map.merge(
            %{
              "scene_facts" => turns,
              "scene_description" => "a flooded crypt",
              "theme" => %{"setting" => "the drowned city", "tone" => "grim"}
            },
            overrides
          )
      },
      %{}
    )
  end

  defp script(context, add \\ %{"ok" => true, "data" => %{"id" => "fact-1"}}) do
    Application.put_env(:bot_army_companion, :answers, %{
      @context => {:ok, context},
      @add => {:ok, add}
    })
  end

  defp answer_with(text, model \\ "test-model") do
    expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
      {:ok, %{text: text, model: model}}
    end)
  end

  # --- who is answered ----------------------------------------------------------

  describe "mine?/2 — only the member the turn was handed to" do
    test "the name in the ask is the name we are configured with" do
      assert PartyNarrator.mine?(ask())
      assert PartyNarrator.mine?(ask(), "companion_bot")
    end

    test "another member's ask is not ours" do
      refute PartyNarrator.mine?(ask(%{"payload" => %{"bot_id" => "someone_else"}}))
      refute PartyNarrator.mine?(%{"bot_id" => "companion"}, "companion_bot")
    end

    test "an unconfigured name matches nothing, not everything" do
      refute PartyNarrator.mine?(ask(), nil)
      refute PartyNarrator.mine?(ask(), "")
      refute PartyNarrator.mine?(%{"bot_id" => ""}, "")
    end

    test "an ask with no name at all is nobody's" do
      refute PartyNarrator.mine?(%{"session_id" => @session})
      refute PartyNarrator.mine?(%{})
      refute PartyNarrator.mine?(:not_a_message)
    end

    test "the payload is read out of the envelope, or given directly" do
      assert PartyNarrator.ask_payload(ask())["session_id"] == @session
      assert PartyNarrator.ask_payload(%{"session_id" => @session})["session_id"] == @session
      assert PartyNarrator.ask_payload(nil) == %{}
    end
  end

  # --- the words -----------------------------------------------------------------

  describe "narrate/1 — the turn becomes words and a fact" do
    test "the narration is read, written, and signed with our own name" do
      script(window(["the door was already open", "she lit a torch"]))
      answer_with("The lock gave way in the dark, and the water took the sound.", "companion-9b")

      assert {:ok, %{text: text, model: "companion-9b"} = written} =
               PartyNarrator.narrate(ask())

      assert text =~ "lock gave way"
      assert written.fact["id"] == "fact-1"

      assert_received {:request, @context, %{"session_id" => @session, "tenant_id" => @tenant}}

      assert_received {:request, @add, fact}
      assert fact["session_id"] == @session
      assert fact["tenant_id"] == @tenant
      assert fact["category"] == "narration"
      assert fact["source"] == "companion_bot"
      assert fact["content"] == text
      # A narrator is asked about a turn, not a person.
      refute Map.has_key?(fact, "user_id")
    end

    test "the log is read through rpg's own read, newest turns last for the model" do
      # rpg's read hands the facts over newest-first; the model is shown them in the
      # order they happened.
      script(window(["newer", "older"]))

      expect(ReflectionAnswerLlmMock, :answer, fn _system, user, _opts ->
        assert user =~ "What has already happened in this window:"
        assert user =~ "older\nnewer"
        {:ok, %{text: "Words.", model: "test-model"}}
      end)

      assert {:ok, _written} = PartyNarrator.narrate(ask())
    end

    test "the prompt carries the turn, the place and the table's theme as data" do
      prompt =
        PartyNarrator.prompt(
          %{
            "scene_description" => "probe",
            "round" => 2,
            "actor" => %{"name" => "Mira"},
            "action" => %{"description" => "the lock is picked"},
            "resolution" => %{"outcome" => "success", "total" => 17, "dc" => 12}
          },
          {:ok,
           %{
             "scene" => "a flooded crypt",
             "theme" => %{
               "setting" => "the drowned city",
               "tone" => "grim",
               "vocabulary" => %{"sword" => "cutlass"}
             },
             "turns" => ["second", "first"]
           }}
        )

      assert prompt =~ "The place: a flooded crypt"
      assert prompt =~ "the drowned city"
      assert prompt =~ "Tone: grim"
      assert prompt =~ "sword → cutlass"
      assert prompt =~ "first\nsecond"
      assert prompt =~ "Who acts: Mira"
      assert prompt =~ "What is attempted: the lock is picked"
      assert prompt =~ "How it went: success (17 against 12)"
      assert prompt =~ "Round: 2"
    end

    test "an empty window is not a window that could not be read" do
      log = %{"ok" => true, "data" => %{"scene_facts" => [], "scene_description" => "probe"}}

      assert {:ok, read} = PartyNarrator.log_from(log)
      assert read["turns"] == []

      prompt = PartyNarrator.prompt(%{"scene_description" => "probe"}, read)
      refute prompt =~ "What has already happened"
      assert prompt =~ "The place: probe"
    end
  end

  # --- what is not answered -------------------------------------------------------

  describe "narrate/1 — the refusals" do
    test "another member's ask is left alone before anything is read" do
      script(window([]))

      log =
        capture_log(fn ->
          assert PartyNarrator.narrate(ask(%{"payload" => %{"bot_id" => "someone_else"}})) ==
                   :not_mine
        end)

      assert log =~ "left alone"
      refute_received {:request, _, _}
    end

    test "an ask with no window is refused, and nothing is read or written" do
      script(window([]))

      log =
        capture_log(fn ->
          assert {:error, :no_session} =
                   PartyNarrator.narrate(ask(%{"payload" => %{"bot_id" => "companion_bot"}}))
        end)

      assert log =~ "names no window"
      refute_received {:request, _, _}
    end

    test "the words are not logged, and a failure is logged as its code" do
      script(window(["a turn nobody should see in a log"]))
      answer_with("The prose that must not reach a log file.")

      log = capture_log(fn -> assert {:ok, _written} = PartyNarrator.narrate(ask()) end)
      assert log =~ "wrote"
      refute log =~ "must not reach a log file"
      refute log =~ "a turn nobody should see in a log"
    end

    test "a model that does not answer writes nothing at all" do
      script(window([]))

      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o -> {:error, :timeout} end)

      log = capture_log(fn -> assert {:error, :timeout} = PartyNarrator.narrate(ask()) end)

      assert log =~ "no words came back"
      refute_received {:request, @add, _}
    end

    test "a log that cannot be read costs the model the log, not the turn" do
      Application.put_env(:bot_army_companion, :answers, %{
        @context => {:error, :timeout},
        @add => {:ok, %{"ok" => true, "data" => %{"id" => "fact-1"}}}
      })

      expect(ReflectionAnswerLlmMock, :answer, fn _system, user, _opts ->
        refute user =~ "What has already happened"
        assert user =~ "the lock is picked"
        {:ok, %{text: "Words from the turn alone.", model: "test-model"}}
      end)

      log = capture_log(fn -> assert {:ok, _written} = PartyNarrator.narrate(ask()) end)

      assert log =~ "the log could not be read"
      assert_received {:request, @add, _fact}
    end

    test "rpg refusing the context read is unreadable, not an empty window, and it is said out loud" do
      Application.put_env(:bot_army_companion, :answers, %{
        @context =>
          {:ok, %{"ok" => false, "error" => "no such session", "code" => "session_not_active"}},
        @add => {:ok, %{"ok" => true, "data" => %{"id" => "fact-1"}}}
      })

      expect(ReflectionAnswerLlmMock, :answer, fn _system, user, _opts ->
        refute user =~ "What has already happened"
        {:ok, %{text: "Words.", model: "test-model"}}
      end)

      log = capture_log(fn -> assert {:ok, _written} = PartyNarrator.narrate(ask()) end)

      # A refusal that comes back as a *reply* is still a read that did not happen: it must
      # reach the log, or a window narrated blind looks exactly like a window that was read.
      assert log =~ "the log could not be read (an unreadable reply)"
      assert PartyNarrator.log_from(%{"ok" => false, "error" => "nope"}) == :unreadable
      assert PartyNarrator.log_from(%{"ok" => true, "data" => %{}}) == :unreadable
      assert PartyNarrator.log_from(:nonsense) == :unreadable
    end

    test "a write rpg refuses is a turn nobody can find, and it says so" do
      script(window([]), %{"ok" => false, "error" => "content is required"})
      answer_with("Words that would not stick.")

      log = capture_log(fn -> assert {:error, :not_written} = PartyNarrator.narrate(ask()) end)

      assert log =~ "was not written"
      refute log =~ "Words that would not stick."
    end

    test "a broker that is gone is a code, never a crash out of the subscription" do
      Application.put_env(:bot_army_companion, :nats_publisher, __MODULE__.RaisingPublisher)

      assert {:error, :crashed} = PartyNarrator.narrate(ask())
    end

    test "something that is not a message is refused quietly" do
      assert PartyNarrator.narrate(:not_a_message) == {:error, :bad_ask}
      assert PartyNarrator.narrate(nil) == {:error, :bad_ask}
    end
  end

  # --- the fact we write ----------------------------------------------------------

  describe "fact_payload/3" do
    test "the name on the words is ours, and no tenant is invented" do
      fact = PartyNarrator.fact_payload(@session, @tenant, "prose")
      assert fact["source"] == "companion_bot"
      assert fact["tenant_id"] == @tenant

      bare = PartyNarrator.fact_payload(@session, nil, "prose")
      refute Map.has_key?(bare, "tenant_id")
    end

    test "the name follows the configuration, not a hardcoded fleet name" do
      Application.put_env(:bot_army_companion, :bot_id, "eir_bot")

      assert PartyNarrator.fact_payload(@session, nil, "prose")["source"] == "eir_bot"
      assert PartyNarrator.bot_id() == "eir_bot"
      assert PartyNarrator.mine?(%{"bot_id" => "eir_bot"})
    end
  end

  describe "the ask's own subject" do
    test "the subscription is the wire subject rpg publishes to" do
      assert PartyNarrator.subject() == "events.rpg.narration.your_turn"
    end

    test "the narrator does not speak in the companion's reflection voice" do
      refute PartyNarrator.system_prompt() =~ "reflection"
      assert PartyNarrator.system_prompt() =~ "narrator"
    end
  end
end
