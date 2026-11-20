defmodule BotArmyCompanion.ReflectionAnswerSealedTest do
  @moduledoc """
  With `seal: true`, her words cross the bus only as ciphertext: the request's system and
  messages travel inside the envelope, the answer comes back sealed and is opened here, and
  a missing key refuses the request instead of sending it plain.
  """
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyCompanion.ReflectionAnswer.Llm.Nats, as: LlmNats
  alias BotArmyCompanion.Sealed

  @words "I haven't told anyone, but I'm scared about the new job"
  @job "7f00b3a1-1111-4c1e-8f2a-77c1d3a9c4b1"

  # A fake llm bot that speaks the sealed protocol: it records what crossed the bus, opens
  # the request, and seals its answer — exactly what llm >= 0.12.0 does.
  defmodule SealedBus do
    @moduledoc false
    @job "7f00b3a1-1111-4c1e-8f2a-77c1d3a9c4b1"

    def request("llm.request.chat", payload, _opts) do
      send(self(), {:wire, payload})
      Process.put(:request, payload)
      {:ok, %{"job_id" => @job}}
    end

    def request("llm.job.status", _payload, _opts) do
      req = Process.get(:request)
      rid = req["request_id"]
      {:ok, inner} = Sealed.open(req["sealed"], Sealed.aad(:request, rid))
      [%{"content" => heard}] = inner["messages"]
      answer = Process.get(:answer, "I hear you: " <> heard)
      {:ok, env} = Sealed.seal(%{"content" => answer}, "k1", Sealed.aad(:response, rid))

      reply =
        %{
          "ok" => true,
          "status" => "completed",
          "result" => %{"sealed" => env, "model_used" => "m", "request_id" => rid}
        }

      send(self(), {:wire, reply})
      {:ok, reply}
    end
  end

  setup do
    System.put_env(
      "LLM_SEALED_KEYS",
      Jason.encode!(%{"k1" => Base.encode64(:crypto.strong_rand_bytes(32))})
    )

    original = Application.get_env(:bot_army_companion, :nats_publisher)
    Application.put_env(:bot_army_companion, :nats_publisher, SealedBus)

    on_exit(fn ->
      System.delete_env("LLM_SEALED_KEYS")

      if original,
        do: Application.put_env(:bot_army_companion, :nats_publisher, original),
        else: Application.delete_env(:bot_army_companion, :nats_publisher)
    end)

    :ok
  end

  defp opts(extra) do
    Keyword.merge(
      [
        subject: "llm.request.chat",
        status_subject: "llm.job.status",
        model_type: "uncensored",
        uncensored_tier: "light",
        lane: "interactive",
        max_tokens: 100,
        budget_ms: 5_000,
        poll_ms: 10,
        submit_timeout_ms: 1_000,
        status_timeout_ms: 1_000,
        seal: true
      ],
      extra
    )
  end

  defp wire do
    Stream.repeatedly(fn ->
      receive do
        {:wire, m} -> m
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  test "her words travel sealed, the answer is opened, nothing readable crosses the bus" do
    assert {:ok, %{text: "I hear you: " <> @words, model: "m"}} =
             LlmNats.answer("you are Eir", @words, opts([]))

    messages = wire()
    assert length(messages) >= 2
    refute Enum.any?(messages, &(Jason.encode!(&1) =~ "scared"))
    refute Enum.any?(messages, &(Jason.encode!(&1) =~ "you are Eir"))

    [request | _] = messages
    refute Map.has_key?(request, "messages")
    refute Map.has_key?(request, "system")
    assert request["model_type"] == "uncensored"
    assert request["uncensored_tier"] == "light"
    assert is_binary(request["request_id"])
  end

  test "each request gets its own request id" do
    LlmNats.answer("s", "a", opts([]))
    [r1 | _] = wire()
    LlmNats.answer("s", "b", opts([]))
    [r2 | _] = wire()
    refute r1["request_id"] == r2["request_id"]
  end

  test "no key: refused before anything is sent, never sent plain" do
    System.delete_env("LLM_SEALED_KEYS")
    assert {:error, :unavailable} = LlmNats.answer("s", @words, opts([]))
    assert wire() == []
  end

  test "an answer that does not open is a model failure, not words" do
    Process.put(:answer, "fine")

    defmodule WrongKeyBus do
      @moduledoc false
      def request("llm.request.chat", _p, _o), do: {:ok, %{"job_id" => "j"}}

      def request("llm.job.status", _p, _o) do
        {:ok, env} = Sealed.seal(%{"content" => "x"}, "k1", Sealed.aad(:response, "someone-else"))
        {:ok, %{"ok" => true, "status" => "completed", "result" => %{"sealed" => env}}}
      end
    end

    Application.put_env(:bot_army_companion, :nats_publisher, WrongKeyBus)
    assert {:error, :model_failed} = LlmNats.answer("s", "w", opts([]))
  end

  test "without seal the request is unchanged (plain, as before)" do
    LlmNats.answer("s", "plain words", opts(seal: false)) |> then(fn _ -> :ok end)
    [request | _] = wire()
    refute Map.has_key?(request, "sealed")
    assert [%{"content" => "plain words"}] = request["messages"]
  end
end
