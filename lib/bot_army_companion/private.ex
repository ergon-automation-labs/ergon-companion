defmodule BotArmyCompanion.Private do
  @moduledoc """
  How this bot mentions private things in a log.

  The companion's whole job is words that are hers: reflections, prompts, the
  PARA files they are read from, and the model's answers. Those words must never
  reach a log file — and the way that fails is never dramatic. It is one
  `Logger.debug("...: \#{inspect(payload)}")`, written by someone who was
  debugging, left in place, and later found in a 500 MB world-readable file that
  outlives every rotation policy. That is not a hypothetical: on 2026-09-26 the
  assembled context of a reflection — her daily log, her tasks, her PARA files —
  was sitting in `/var/log/bot_army/companion_bot.log`.

  So a log line about a private value says what the value *is*, in shape and in
  size, and never what it says:

      Logger.debug("write_to_para: formatting a reflection (\#{Private.describe(reflection)})")
      # => write_to_para: formatting a reflection (a map (9 keys: active_tasks, angle, ...))

  Keys and counts are safe because they are ours. Values are not, because they
  are hers.
  """

  @doc """
  Describe a value without printing it.

  Scalars (`nil`, atoms, booleans, numbers) are printed as they are: a number
  cannot carry a paragraph, and hiding `angle: 3` would only make the log
  useless. Everything that can hold words is described instead — a binary by its
  size, a map by its keys, a list by its length, a struct by its module (an
  exception's `message` is content too).
  """
  def describe(nil), do: "nothing"

  def describe(value) when is_boolean(value) or is_number(value), do: inspect(value)

  def describe(value) when is_atom(value), do: inspect(value)

  def describe(value) when is_binary(value), do: "#{byte_size(value)} bytes of text"

  def describe(value) when is_list(value), do: "a list of #{length(value)}"

  def describe(value) when is_tuple(value), do: "a tuple of #{tuple_size(value)}"

  def describe(%{__struct__: module} = value),
    do: "#{inspect(module)} (#{describe_keys(value)})"

  def describe(value) when is_map(value), do: "a map (#{describe_keys(value)})"

  def describe(value) when is_function(value), do: "a function"

  def describe(_other), do: "an opaque value"

  # The key list is sorted so the same value always describes the same way;
  # `Map.keys/1` makes no ordering promise, and a log line that changes shape
  # between identical events wastes the reader's attention. `__struct__` and
  # `__exception__` are Elixir's own bookkeeping and tell a reader nothing.
  defp describe_keys(map) do
    keys =
      map
      |> Map.keys()
      |> Enum.reject(&internal_key?/1)
      |> Enum.map(&key_name/1)
      |> Enum.sort()

    case keys do
      [] -> "no keys"
      [one] -> "1 key: #{one}"
      many -> "#{length(many)} keys: #{Enum.join(many, ", ")}"
    end
  end

  defp internal_key?(key), do: key in [:__struct__, :__exception__]

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_integer(key), do: Integer.to_string(key)
  defp key_name(_other), do: "?"
end
