defmodule BotArmyCompanion.LettersSoulTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyCompanion.Letters.Soul

  @config %{"identity" => %{"name" => "Eir"}, "character" => "A pen pal who writes back."}

  defmodule Bus do
    @moduledoc false
    def request("soul.get", %{"bot_id" => "companion"}, _opts),
      do: Process.get(:soul_reply, {:error, :timeout})
  end

  defp get(reply) do
    Process.put(:soul_reply, reply)
    Soul.get(publisher: Bus)
  end

  test "an active soul with a name and a character is returned as its config" do
    assert {:ok, @config} =
             get({:ok, %{"ok" => true, "data" => %{"config" => @config, "active" => true}}})
  end

  test "the reply inside an event envelope reads the same" do
    reply = %{"payload" => %{"ok" => true, "data" => %{"config" => @config}}}
    assert {:ok, @config} = get({:ok, reply})
  end

  test "no soul, an inactive one, or a hollow one is :no_soul, never a generic reply" do
    for reply <- [
          %{"ok" => true, "data" => nil},
          %{"ok" => false, "error" => "not found"},
          %{"ok" => true, "data" => %{"config" => @config, "active" => false}},
          %{"ok" => true, "data" => %{"config" => %{}}},
          %{"ok" => true, "data" => %{"config" => %{"identity" => %{"name" => "Eir"}}}},
          %{
            "ok" => true,
            "data" => %{"config" => %{"identity" => %{"name" => " "}, "character" => "x"}}
          },
          %{"surprise" => 1}
        ] do
      assert {:error, :no_soul} = get({:ok, reply}), inspect(reply)
    end
  end

  test "a bus that does not answer is :soul_unavailable, which is not the same as no soul" do
    assert {:error, :soul_unavailable} = get({:error, :timeout})
  end
end
