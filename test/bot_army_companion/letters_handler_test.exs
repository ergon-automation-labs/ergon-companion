defmodule BotArmyCompanion.LettersHandlerTest do
  use ExUnit.Case, async: false
  @moduletag :handlers

  alias BotArmyCompanion.Handlers.LettersHandler
  alias BotArmyCompanion.Sealed

  @secret "my sister and I haven't spoken since June"
  @send "companion.letters.send"
  @thread "companion.letters.thread"

  # A store that records what it was asked and answers from a script, with no database.
  defmodule Store do
    @moduledoc false
    def send_letter(text, rid, opts) do
      send(Process.get(:test), {:send_letter, text, rid, opts})

      Process.get(
        :send_reply,
        {:ok, %{"letter" => %{"id" => "l1", "text" => text}, "reply" => nil}, :created}
      )
    end

    def thread(opts) do
      send(Process.get(:test), {:thread, opts})
      Process.get(:thread_reply, {:ok, [%{"id" => "l1", "text" => "x"}]})
    end
  end

  setup do
    Process.put(:test, self())

    System.put_env(
      "LETTERS_SEALED_KEYS",
      Jason.encode!(%{"letters1" => Base.encode64(:binary.copy(<<6>>, 32))})
    )

    System.put_env(
      "LLM_SEALED_KEYS",
      Jason.encode!(%{"k1" => Base.encode64(:binary.copy(<<7>>, 32))})
    )

    on_exit(fn ->
      System.delete_env("LETTERS_SEALED_KEYS")
      System.delete_env("LLM_SEALED_KEYS")
    end)

    :ok
  end

  defp request(inner, rid \\ "r1") do
    {:ok, env} = Sealed.seal(inner, Sealed.letters_kid(), Sealed.letters_aad(:request, rid))
    %{"request_id" => rid, "sealed" => env}
  end

  defp handle(subject, body), do: LettersHandler.handle(subject, body, letters: Store)

  defp open_answer(%{"request_id" => rid, "sealed" => env}) do
    {:ok, data} = Sealed.open(env, Sealed.letters_aad(:response, rid))
    data
  end

  test "it answers exactly its two subjects" do
    assert LettersHandler.subjects() == [@send, @thread]
    assert {:error, :unknown_subject, _} = handle("companion.letters.delete", request(%{}))
  end

  describe "refused before the store is asked anything" do
    test "an unsealed request, with the words in the clear" do
      for body <- [
            %{"text" => @secret},
            %{"request_id" => "r1", "text" => @secret},
            %{},
            "junk",
            nil
          ] do
        assert {:error, :unsealed, msg} = handle(@send, body)
        refute msg =~ "sister"
      end

      refute_received {:send_letter, _, _, _}
    end

    test "a request sealed under the LLM channel's key" do
      {:ok, env} = Sealed.seal(%{"text" => @secret}, "k1", Sealed.letters_aad(:request, "r1"))
      assert {:error, :bad_seal, _} = handle(@send, %{"request_id" => "r1", "sealed" => env})
      refute_received {:send_letter, _, _, _}
    end

    test "an envelope bound to another request id" do
      body = request(%{"text" => @secret}, "r-other")
      assert {:error, :bad_seal, _} = handle(@send, %{body | "request_id" => "r1"})
      refute_received {:send_letter, _, _, _}
    end

    test "an envelope sealed for the LLM bot, replayed here under the letters key" do
      {:ok, env} =
        Sealed.seal(%{"text" => @secret}, Sealed.letters_kid(), Sealed.aad(:request, "r1"))

      assert {:error, :bad_seal, _} = handle(@send, %{"request_id" => "r1", "sealed" => env})
      refute_received {:send_letter, _, _, _}
    end

    test "a tampered envelope" do
      body = request(%{"text" => @secret})
      <<b, rest::binary>> = Base.decode64!(body["sealed"]["ct"])

      tampered =
        put_in(body, ["sealed", "ct"], Base.encode64(<<Bitwise.bxor(b, 1), rest::binary>>))

      assert {:error, :bad_seal, _} = handle(@send, tampered)
      refute_received {:send_letter, _, _, _}
    end

    test "a missing or empty request id" do
      body = request(%{"text" => "hi"})
      assert {:error, :unsealed, _} = handle(@send, Map.delete(body, "request_id"))
      assert {:error, :unsealed, _} = handle(@send, %{body | "request_id" => ""})
    end

    test "no key on this node: the 30013 panel, or a node that is not on the channel" do
      body = request(%{"text" => @secret})
      System.delete_env("LETTERS_SEALED_KEYS")
      assert {:error, :bad_seal, _} = handle(@send, body)
      refute_received {:send_letter, _, _, _}
    end

    test "one code, no detail, for every way an envelope can be wrong" do
      wrong = [
        %{"request_id" => "r1", "sealed" => %{"kid" => "letters1"}},
        %{
          "request_id" => "r1",
          "sealed" => %{
            "kid" => "other",
            "iv" => "x",
            "ct" => "x",
            "tag" => "x",
            "v" => 1,
            "alg" => "A256GCM"
          }
        }
      ]

      for body <- wrong,
          do:
            assert({:error, :bad_seal, "that request could not be opened"} = handle(@send, body))
    end
  end

  describe "a sealed send" do
    test "reaches the store with the opened text and the request id, and the answer is sealed" do
      assert {:ok, answer} = handle(@send, request(%{"text" => @secret}, "r9"))

      assert_received {:send_letter, @secret, "r9", _}
      assert answer["request_id"] == "r9"
      refute Jason.encode!(answer) =~ "sister"

      data = open_answer(answer)
      assert data["letter"]["text"] == @secret
      assert data["duplicate"] == false
    end

    test "a repeat says so" do
      Process.put(:send_reply, {:ok, %{"letter" => %{"id" => "l1"}, "reply" => nil}, :existing})
      assert {:ok, answer} = handle(@send, request(%{"text" => "again"}))
      assert open_answer(answer)["duplicate"] == true
    end

    test "a crisis reply travels back in the same sealed answer" do
      Process.put(
        :send_reply,
        {:ok,
         %{"letter" => %{"id" => "l1"}, "reply" => %{"kind" => "safety", "text" => "Abby, ..."}},
         :created}
      )

      assert {:ok, answer} = handle(@send, request(%{"text" => "I want to die"}))
      assert open_answer(answer)["reply"]["kind"] == "safety"
    end
  end

  describe "a sealed thread read" do
    test "asks for its limit and answers sealed" do
      assert {:ok, answer} = handle(@thread, request(%{"limit" => 7}))
      assert_received {:thread, opts}
      assert opts[:limit] == 7
      assert open_answer(answer)["letters"] == [%{"id" => "l1", "text" => "x"}]
      refute Jason.encode!(answer) =~ ~s("text":"x")
    end

    test "a limit that is not a number is the default, not a crash" do
      assert {:ok, _} = handle(@thread, request(%{"limit" => "all of them"}))
      assert_received {:thread, opts}
      assert opts[:limit] == 40
    end
  end

  describe "refusals from the store use fixed words and never echo the sender" do
    test "each reason maps to a code, and the message never contains the letter" do
      cases = [
        {:no_text, :validation_error},
        {{:too_long, 8000}, :validation_error},
        {:needs_request_id, :validation_error},
        {:invalid, :validation_error},
        {:store_unavailable, :unavailable},
        {:sealed_key_not_configured, :unavailable},
        {:something_unexpected, :unavailable}
      ]

      for {reason, code} <- cases do
        Process.put(:send_reply, {:error, reason})
        assert {:error, ^code, msg} = handle(@send, request(%{"text" => @secret}))
        refute msg =~ "sister"
      end
    end

    test "a store that is down on a thread read is unavailable" do
      Process.put(:thread_reply, {:error, :store_unavailable})
      assert {:error, :unavailable, _} = handle(@thread, request(%{"limit" => 5}))
    end
  end
end
