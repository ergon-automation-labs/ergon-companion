defmodule BotArmyCompanion.SealedTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyCompanion.Sealed

  setup do
    System.put_env(
      "LLM_SEALED_KEYS",
      Jason.encode!(%{"k1" => Base.encode64(:binary.copy(<<7>>, 32))})
    )

    on_exit(fn -> System.delete_env("LLM_SEALED_KEYS") end)
    :ok
  end

  # The SAME vector as the llm bot's sealed_test.exs, cross-checked 2026-11-19 against
  # Python's cryptography AESGCM. If this module and BotArmyLlm.Sealed ever disagree on the
  # format, one of the two suites fails here.
  test "known-answer vector, shared with the llm bot" do
    {:ok, env} =
      Sealed.seal(%{"content" => "hi"}, "k1", "llm.sealed.v1|request|r1", :binary.copy(<<1>>, 12))

    assert env == %{
             "v" => 1,
             "alg" => "A256GCM",
             "kid" => "k1",
             "iv" => "AQEBAQEBAQEBAQEB",
             "ct" => "DcPq2P7LiWCl9uYDGF5STA==",
             "tag" => "om/rTfGK3x0kdB8IylLBLA=="
           }
  end

  test "a sealed map opens under the same purpose and not another" do
    {:ok, env} = Sealed.seal(%{"content" => "dear Eir"}, "k1", Sealed.aad(:request, "r1"))
    refute Jason.encode!(env) =~ "dear Eir"
    assert {:ok, %{"content" => "dear Eir"}} = Sealed.open(env, Sealed.aad(:request, "r1"))
    assert {:error, :sealed_bad_ciphertext} = Sealed.open(env, Sealed.aad(:response, "r1"))
  end

  test "no key is refused by name, never a plaintext fallback" do
    System.delete_env("LLM_SEALED_KEYS")
    assert {:error, :sealed_key_not_configured} = Sealed.seal(%{}, "k1", "a")
  end

  test "the default kid is k1" do
    assert Sealed.current_kid() == "k1"
  end
end
