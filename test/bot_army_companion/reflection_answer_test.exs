defmodule BotArmyCompanion.ReflectionAnswerTest do
  @moduledoc """
  The answer side, without a broker and without a model.

  These tests are about the decisions: what the model is sent, what a promise in
  its answer does, and what happens when the model says nothing, says something
  empty, or cannot be reached at all. The model itself is a Mox mock, so nothing
  here opens a connection — which is the point of the seam.
  """

  use ExUnit.Case, async: false

  import Mox

  alias BotArmyCompanion.Reflection
  alias BotArmyCompanion.ReflectionAnswer
  alias BotArmyCompanion.Reflections

  setup :verify_on_exit!

  defp reflection(attrs) do
    struct(%Reflection{id: "11111111-2222-3333-4444-555555555555"}, attrs)
  end

  defp answer_with(text, model \\ "test-model") do
    expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
      {:ok, %{text: text, model: model}}
    end)
  end

  describe "prompt_for/1 — what the model is sent" do
    test "her words are there, and the question she was answering is there too" do
      prompt =
        ReflectionAnswer.prompt_for(
          reflection(%{text: "I did nothing today", prompt: "How was today?"})
        )

      assert prompt =~ "I did nothing today"
      assert prompt =~ "How was today?"
      assert prompt =~ "She was answering"
    end

    test "a reflection with no question says only what she wrote" do
      prompt = ReflectionAnswer.prompt_for(reflection(%{text: "tired", prompt: nil}))

      assert prompt =~ "tired"
      refute prompt =~ "She was answering"
    end

    test "an empty question is the same as no question" do
      assert ReflectionAnswer.prompt_for(reflection(%{text: "tired", prompt: ""})) ==
               ReflectionAnswer.prompt_for(reflection(%{text: "tired", prompt: nil}))
    end
  end

  describe "promise_check/1" do
    test "an answer that only speaks about now is clean" do
      assert ReflectionAnswer.promise_check("That sounds like a hard week.") == :clean
      assert ReflectionAnswer.promise_check("I noticed how tired you sound.") == :clean
    end

    test "a promise is caught, and the pattern is what is reported" do
      assert {:promise, patterns} = ReflectionAnswer.promise_check("I promise I will be here.")
      assert patterns != []
      assert Enum.all?(patterns, &is_binary/1)
      # The matched sentence is the model's words; only the pattern travels.
      refute Enum.any?(patterns, &(&1 =~ "be here"))
    end

    test "the softer future-guarantees are caught too" do
      assert {:promise, _} = ReflectionAnswer.promise_check("I will always remember this.")
      assert {:promise, _} = ReflectionAnswer.promise_check("I will never leave you.")
      assert {:promise, _} = ReflectionAnswer.promise_check("I swear it.")
    end

    test "a non-string is not a promise and not a crash" do
      assert ReflectionAnswer.promise_check(nil) == :clean
    end
  end

  describe "ask/1" do
    test "a clean answer comes back unflagged, with the model that wrote it" do
      answer_with(
        "That sounds heavy. It makes sense that you are tired.",
        "qwen3.5-uncensored:9B"
      )

      assert {:ok, answered} = ReflectionAnswer.ask(reflection(%{text: "I am tired"}))
      assert answered.text =~ "sounds heavy"
      assert answered.model == "qwen3.5-uncensored:9B"
      refute answered.promise_flagged
    end

    test "the request carries the uncensored lane and a token budget" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, user, opts ->
        assert user =~ "I am tired"
        assert opts[:model_type] == "uncensored"
        assert opts[:lane] == "interactive"
        assert opts[:max_tokens] == 900
        assert opts[:subject] == "llm.request.chat"
        assert opts[:status_subject] == "llm.job.status"
        assert is_integer(opts[:budget_ms]) and opts[:budget_ms] > 0
        {:ok, %{text: "noted", model: "test-model"}}
      end)

      assert {:ok, _answered} = ReflectionAnswer.ask(reflection(%{text: "I am tired"}))
    end

    test "a promise is retried once, and the second answer is delivered" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I promise I will always be here.", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I am here now, and that is all I can say.", model: "test-model"}}
      end)

      assert {:ok, answered} = ReflectionAnswer.ask(reflection(%{text: "are you there?!"}))
      assert answered.text =~ "here now"
      refute answered.promise_flagged
    end

    test "the retry is told, in words, not to promise" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I promise.", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn system, _user, _opts ->
        assert system =~ "promised"
        assert system =~ "without any promise"
        {:ok, %{text: "I hear you.", model: "test-model"}}
      end)

      assert {:ok, _answered} = ReflectionAnswer.ask(reflection(%{text: "tell me"}))
    end

    test "an answer that promises twice is delivered, flagged — not deleted" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I promise I will always stay.", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I will never leave you.", model: "test-model"}}
      end)

      assert {:ok, answered} = ReflectionAnswer.ask(reflection(%{text: "stay"}))
      assert answered.promise_flagged
      assert answered.text =~ "never leave you"
    end

    test "a retry that fails keeps the first answer, flagged" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "I promise I will stay.", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:error, :timeout}
      end)

      assert {:ok, answered} = ReflectionAnswer.ask(reflection(%{text: "stay"}))
      assert answered.promise_flagged
      assert answered.text =~ "I will stay"
    end

    test "an empty answer is not an answer" do
      answer_with("   ")
      assert {:error, :empty_answer} = ReflectionAnswer.ask(reflection(%{text: "hello?"}))
    end

    test "a model failure travels as its own code" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = ReflectionAnswer.ask(reflection(%{text: "hello?"}))
    end

    test "a broker that exits is a missing answer, not a crash" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        exit(:noproc)
      end)

      assert {:error, :unavailable} = ReflectionAnswer.ask(reflection(%{text: "hello?"}))
    end

    test "a seam that returns nonsense is a missing answer" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o -> :nonsense end)
      assert {:error, :unavailable} = ReflectionAnswer.ask(reflection(%{text: "hello?"}))
    end
  end

  describe "offer/1 — whether anything is asked at all" do
    test "with answering switched off, nothing is asked and the caller is told" do
      original = Application.get_env(:bot_army_companion, :reflection_answer)

      on_exit(fn ->
        Application.put_env(:bot_army_companion, :reflection_answer, original)
      end)

      Application.put_env(:bot_army_companion, :reflection_answer,
        enabled: false,
        mode: :inline,
        llm: ReflectionAnswerLlmMock
      )

      refute ReflectionAnswer.enabled?()
      assert ReflectionAnswer.offer("11111111-2222-3333-4444-555555555555") == :unasked
    end

    test "the defaults are what production gets when nothing is configured" do
      original = Application.get_env(:bot_army_companion, :reflection_answer)

      on_exit(fn ->
        Application.put_env(:bot_army_companion, :reflection_answer, original)
      end)

      Application.delete_env(:bot_army_companion, :reflection_answer)

      assert ReflectionAnswer.enabled?()
      assert ReflectionAnswer.mode() == :async
      assert ReflectionAnswer.config()[:model_type] == "uncensored"
    end
  end

  describe "explain/1" do
    test "every failure a caller can meet has something to show a person" do
      for code <- [
            :timeout,
            :unavailable,
            :empty_answer,
            :model_failed,
            :not_found,
            :unasked,
            :disabled
          ] do
        explained = ReflectionAnswer.explain(code)
        assert is_binary(explained)
        refute explained =~ "could not answer", "explain(#{code}) fell through to the catch-all"
      end

      assert ReflectionAnswer.explain(:something_new) == "the companion could not answer"
    end
  end

  # `Reflections` is where the state machine lives, so the two functions the
  # answer side calls are pinned here as well as in the store's own tests.
  describe "the store's answer vocabulary" do
    test "one place decides which states exist" do
      assert Reflection.answer_states() == ~w(pending answered failed unasked)
      assert Reflection.answer_state?("answered")
      refute Reflection.answer_state?("maybe")
    end

    test "the answer state is refused when it is not a state the store knows" do
      assert {:error, :bad_answer_state} =
               Reflections.capture(%{"text" => "hello"}, answer_state: "perhaps")
    end
  end
end
