defmodule BotArmyCompanion.Letters.Soul do
  @moduledoc """
  Eir's soul, read from the memory bot's souls table (`soul.get`, key `companion`).

  A letter with no soul behind it would be a generic reply carrying none of her refusals ("never
  claims to be human", the safety rule, the boundaries on gentle influence). So a missing,
  inactive or hollow soul is a refusal by name (`:no_soul`), and the letter is not written.
  """

  @bot_id "companion"

  @doc "The soul's config map, or `{:error, :no_soul | :soul_unavailable}`."
  @spec get(keyword()) :: {:ok, map()} | {:error, :no_soul | :soul_unavailable}
  def get(opts \\ []) do
    publisher =
      Keyword.get(opts, :publisher) ||
        Application.get_env(
          :bot_army_companion,
          :nats_publisher,
          BotArmyLibraryRuntime.NATS.Publisher
        )

    case request(publisher) do
      {:ok, reply} -> parse(reply)
      {:error, _} -> {:error, :soul_unavailable}
    end
  end

  defp request(publisher) do
    publisher.request("soul.get", %{"bot_id" => @bot_id}, timeout_ms: 10_000)
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc """
  Read a `soul.get` reply. The bot answers `%{"ok" => true, "data" => %{"config" => ..., "active" => ...}}`
  (or the same inside an event envelope's `"payload"`), and `data: nil` when there is no soul.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, :no_soul}
  def parse(%{"payload" => %{} = inner}), do: parse(inner)

  def parse(%{"ok" => true, "data" => %{"config" => %{} = config} = data}) do
    if Map.get(data, "active") == false or not usable?(config),
      do: {:error, :no_soul},
      else: {:ok, config}
  end

  def parse(_other), do: {:error, :no_soul}

  # Enough of a soul to write as her: a name and a character.
  defp usable?(config) do
    name = get_in(config, ["identity", "name"])
    character = config["character"]

    is_binary(name) and String.trim(name) != "" and is_binary(character) and
      String.trim(character) != ""
  end
end
