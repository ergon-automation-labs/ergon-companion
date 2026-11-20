defmodule BotArmyCompanion.RpgCharacter do
  @moduledoc """
  Asks the RPG bot to make sure the companion has a character.

  The RPG bot answers `ensure` with the existing character or creates one from its
  archetype table (the companion is a Face) and the soul's `identity.name`.
  """

  require Logger

  @spec provision() :: {:ok, map()} | {:error, term()}
  def provision do
    case helper().ensure(bot_id()) do
      {:ok, character} = ok ->
        Logger.info("[RpgCharacter] #{bot_id()} is #{character["name"]} the #{character["class"]}")
        ok

      {:error, reason} = error ->
        Logger.warning("[RpgCharacter] #{bot_id()} has no character yet: #{inspect(reason)}")
        error
    end
  end

  defp bot_id, do: BotArmyCompanion.PartyNarrator.bot_id()

  defp helper do
    Application.get_env(
      :bot_army_companion,
      :rpg_bot_character,
      BotArmyLibraryRuntime.RPG.BotCharacter
    )
  end
end
