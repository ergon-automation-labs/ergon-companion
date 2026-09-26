defmodule BotArmyCompanion.ReflectionsAnswerDbTest do
  @moduledoc """
  The answer side against a live Postgres.

  The pure tests beside this file prove the decisions; this one proves that the
  decisions survive the store: that a captured reflection starts out saying an
  answer is coming, that an answer is recorded on the row it belongs to, that a
  failure leaves her words exactly where they were, and that answering can be
  switched off without the row pretending otherwise.

  Excluded from the default suite; run with `mix test --include integration`.
  """

  use ExUnit.Case, async: false

  import Mox

  @moduletag :stores

  alias BotArmyCompanion.ReflectionAnswer
  alias BotArmyCompanion.Reflections
  alias BotArmyCompanion.Repo
  alias BotArmyCompanion.Test.PostgresHelper

  setup :verify_on_exit!

  describe "the answer side (live Postgres)" do
    @describetag :integration

    setup do
      start_supervised!(Repo)
      PostgresHelper.reset_schema!(Repo)
      assert :ok = BotArmyCompanion.Release.migrate()
      :ok
    end

    defp capture(text, opts \\ []) do
      assert {:ok, view} = Reflections.capture(%{"text" => text}, opts)
      view
    end

    defp reload(id) do
      assert {:ok, view} = Reflections.get(id)
      view
    end

    test "a captured reflection says an answer is coming" do
      view = capture("I did not sleep.")

      assert view["answer"]["state"] == "pending"
      assert view["answer"]["text"] == nil
      assert view["answer"]["answered_at"] == nil
      assert view["answer"]["promise_flagged"] == false
    end

    test "answering switched off stores the truth instead of a promise we cannot keep" do
      view = capture("I did not sleep.", answer_state: "unasked")

      assert view["answer"]["state"] == "unasked"
    end

    test "the offer runs the model inline, and the row carries the answer" do
      expect(ReflectionAnswerLlmMock, :answer, fn _system, user, _opts ->
        assert user =~ "I did not sleep."
        {:ok, %{text: "Not sleeping makes everything louder.", model: "qwen3.5-uncensored:9B"}}
      end)

      captured = capture("I did not sleep.")
      assert {:ok, answered} = ReflectionAnswer.offer(captured["id"])

      stored = reload(captured["id"])
      assert stored["answer"]["state"] == "answered"
      assert stored["answer"]["text"] =~ "louder"
      assert stored["answer"]["model"] == "qwen3.5-uncensored:9B"
      assert stored["answer"]["error"] == nil
      assert stored["answer"]["answered_at"] != nil
      # The answer is on the row, not in place of her words.
      assert stored["text"] == "I did not sleep."
      assert answered["answer"]["state"] == "answered"
    end

    test "a model that cannot be reached leaves a named failure and keeps her words" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:error, :timeout}
      end)

      captured = capture("I did not sleep.")
      # The offer succeeded at what it promises: the failure is recorded on the
      # row, where a reader can see it, rather than raised at the caller.
      assert {:ok, offered} = ReflectionAnswer.offer(captured["id"])
      assert offered["answer"]["state"] == "failed"

      stored = reload(captured["id"])
      assert stored["answer"]["state"] == "failed"
      assert stored["answer"]["error"] == "timeout"
      assert stored["answer"]["text"] == nil
      assert stored["text"] == "I did not sleep."
    end

    test "a queued reflection asked about a row that is not there is a refusal" do
      assert {:error, :not_found} =
               ReflectionAnswer.answer("11111111-2222-3333-4444-555555555555")
    end

    test "the promise flag survives the store, so a reader can see it" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:ok, %{text: "I promise I will always be here.", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:ok, %{text: "I will never leave you.", model: "test-model"}}
      end)

      captured = capture("stay with me")
      assert {:ok, _view} = ReflectionAnswer.offer(captured["id"])

      stored = reload(captured["id"])
      assert stored["answer"]["state"] == "answered"
      assert stored["answer"]["promise_flagged"] == true
      assert stored["answer"]["text"] =~ "never leave you"
    end

    test "the newest answer does not rewrite the reflection it answers" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:ok, %{text: "That is a lot to carry.", model: "test-model"}}
      end)

      assert {:ok, captured} =
               Reflections.capture(%{
                 "text" => "  I said I would rest.  ",
                 "prompt" => "How was today?"
               })

      assert {:ok, _view} = ReflectionAnswer.offer(captured["id"])

      stored = reload(captured["id"])
      assert stored["text"] == "  I said I would rest.  "
      assert stored["prompt"] == "How was today?"
      assert stored["answer"]["text"] == "That is a lot to carry."
    end

    test "a second answer replaces the first, because a row holds one answer" do
      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:ok, %{text: "first", model: "test-model"}}
      end)

      expect(ReflectionAnswerLlmMock, :answer, fn _s, _u, _o ->
        {:ok, %{text: "second", model: "test-model"}}
      end)

      captured = capture("again")
      assert {:ok, _view} = ReflectionAnswer.offer(captured["id"])
      assert reload(captured["id"])["answer"]["text"] == "first"

      assert {:ok, _view} = ReflectionAnswer.offer(captured["id"])
      assert reload(captured["id"])["answer"]["text"] == "second"
    end

    test "the answer state index exists, so 'what is still waiting' is a question" do
      capture("one", answer_state: "unasked")
      capture("two")

      assert {:ok, views} = Reflections.list(nil)
      assert Enum.count(views, &(&1["answer"]["state"] == "pending")) == 1
      assert Enum.count(views, &(&1["answer"]["state"] == "unasked")) == 1
    end
  end
end
