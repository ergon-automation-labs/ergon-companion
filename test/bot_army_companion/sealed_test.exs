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

  describe "the letters channel (the 30014 panel) has a key of its own" do
    setup do
      System.put_env(
        "LETTERS_SEALED_KEYS",
        Jason.encode!(%{"letters1" => Base.encode64(:binary.copy(<<9>>, 32))})
      )

      on_exit(fn -> System.delete_env("LETTERS_SEALED_KEYS") end)
      :ok
    end

    test "the companion holds both and each envelope opens under its own channel" do
      assert Sealed.letters_kid() == "letters1"

      {:ok, to_llm} = Sealed.seal(%{"a" => 1}, Sealed.current_kid(), "x")
      {:ok, to_panel} = Sealed.seal(%{"a" => 2}, Sealed.letters_kid(), "x")

      assert {:ok, %{"a" => 1}} = Sealed.open(to_llm, "x")
      assert {:ok, %{"a" => 2}} = Sealed.open(to_panel, "x")
      refute to_llm["ct"] == to_panel["ct"]
    end

    test "the channels are separate keys: one cannot open the other's envelope" do
      {:ok, to_panel} = Sealed.seal(%{"a" => 2}, Sealed.letters_kid(), "x")

      # Re-label it as the LLM channel's kid: the wrong key, so it must not open.
      assert {:error, :sealed_bad_ciphertext} = Sealed.open(%{to_panel | "kid" => "k1"}, "x")
    end

    test "with only the LLM key configured, a letters envelope is refused by name" do
      {:ok, to_panel} = Sealed.seal(%{"a" => 2}, Sealed.letters_kid(), "x")
      System.delete_env("LETTERS_SEALED_KEYS")

      assert {:error, {:sealed_unknown_key, "letters1"}} = Sealed.open(to_panel, "x")
    end

    test "with only the letters key configured, the LLM channel is refused by name" do
      System.delete_env("LLM_SEALED_KEYS")

      assert {:error, {:sealed_unknown_key, "k1"}} =
               Sealed.seal(%{}, Sealed.current_kid(), "x")
    end
  end
end
