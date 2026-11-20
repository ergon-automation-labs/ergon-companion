defmodule BotArmyCompanion.RpgCharacterTest do
  use ExUnit.Case, async: false
  @moduletag :core

  defmodule Found do
    def ensure(bot_id) do
      send(self(), {:ensured, bot_id})
      {:ok, %{"name" => "Eir", "class" => "Face"}}
    end
  end

  defmodule Down do
    def ensure(bot_id) do
      send(self(), {:ensured, bot_id})
      {:error, :rpg_unavailable}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:bot_army_companion, :rpg_bot_character) end)
  end

  test "asks the RPG bot to ensure the companion's own character" do
    Application.put_env(:bot_army_companion, :rpg_bot_character, Found)

    assert {:ok, %{"name" => "Eir", "class" => "Face"}} =
             BotArmyCompanion.RpgCharacter.provision()

    assert_received {:ensured, "companion_bot"}
  end

  test "it asks under the name the party narrator answers to, so the narrator speaks for her" do
    Application.put_env(:bot_army_companion, :rpg_bot_character, Found)
    Application.put_env(:bot_army_companion, :bot_id, "someone_else")
    on_exit(fn -> Application.delete_env(:bot_army_companion, :bot_id) end)

    BotArmyCompanion.RpgCharacter.provision()
    assert_received {:ensured, "someone_else"}
    assert BotArmyCompanion.PartyNarrator.mine?(%{"bot_id" => "someone_else"})
  end

  test "an unreachable RPG bot is an error answer, not a crash" do
    Application.put_env(:bot_army_companion, :rpg_bot_character, Down)

    assert {:error, :rpg_unavailable} = BotArmyCompanion.RpgCharacter.provision()
    assert_received {:ensured, "companion_bot"}
  end
end
