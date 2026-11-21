defmodule BotArmyCompanion.Sealed do
  @moduledoc """
  The companion's half of sealed LLM requests: her words cross NATS as ciphertext.

  The same envelope as the llm bot's `BotArmyLlm.Sealed` (llm >= 0.12.0), copied rather
  than shared so neither bot waits on a library rollout. The two copies are held to one
  format by a known-answer vector in both test suites (`test/bot_army_companion/sealed_test.exs`
  and the llm bot's `sealed_test.exs`), cross-checked against Python's `cryptography` AESGCM:
  if either copy drifts, its own suite fails.

      %{"v" => 1, "alg" => "A256GCM", "kid" => "k1", "iv" => b64, "ct" => b64, "tag" => b64}

  AES-256-GCM over the JSON of a map, bound to `aad(:request | :response, request_id)`.
  Keys: `LLM_SEALED_KEYS`, a JSON object of kid to base64 32-byte key, from the live-only
  secrets pillar (`make ensure-llm-sealed-key`). `current_kid/0` is the kid this bot seals
  under (`k1` unless `LLM_SEALED_KID` says otherwise).
  """

  @version 1
  @alg "A256GCM"
  @iv_bytes 12

  @doc "The additional authenticated data for one direction of one request."
  @spec aad(:request | :response, String.t()) :: String.t()
  def aad(direction, request_id) when direction in [:request, :response],
    do: "llm.sealed.v#{@version}|#{direction}|#{request_id}"

  @doc """
  The additional authenticated data for one direction of one request on the letters channel
  (the 30014 panel). A different purpose string from `aad/2`'s, so an envelope sealed for the
  LLM bot can never be accepted as a letter request, or the reverse, even under a shared key.
  """
  @spec letters_aad(:request | :response, String.t()) :: String.t()
  def letters_aad(direction, request_id) when direction in [:request, :response],
    do: "companion.letters.v1|#{direction}|#{request_id}"

  @doc """
  The additional authenticated data for a letter's body at rest, bound to its row id, so a
  body copied onto another row does not open.
  """
  @spec letter_at_rest_aad(String.t()) :: String.t()
  def letter_at_rest_aad(letter_id) when is_binary(letter_id),
    do: "companion.letter.v1|" <> letter_id

  @doc """
  The key id of the letters channel (the 30014 panel). Fixed, not configured: a kid that
  could be pointed at the LLM key would turn two separate channels back into one.
  """
  @spec letters_kid() :: String.t()
  def letters_kid, do: "letters1"

  @doc "The key id this bot seals under when it talks to the LLM bot."
  @spec current_kid() :: String.t()
  def current_kid do
    case BotArmyLibraryRuntime.ConfigLoader.get("LLM_SEALED_KID") do
      kid when is_binary(kid) and kid != "" -> kid
      _ -> "k1"
    end
  end

  @doc "Seal a map. `iv` is injectable only for the known-answer test."
  @spec seal(map(), String.t(), String.t(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def seal(map, kid, aad, iv \\ nil) when is_map(map) and is_binary(aad) do
    with {:ok, key} <- key(kid) do
      iv = iv || :crypto.strong_rand_bytes(@iv_bytes)

      {ct, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Jason.encode!(map), aad, true)

      {:ok,
       %{
         "v" => @version,
         "alg" => @alg,
         "kid" => kid,
         "iv" => Base.encode64(iv),
         "ct" => Base.encode64(ct),
         "tag" => Base.encode64(tag)
       }}
    end
  end

  @doc "Open an envelope sealed for `aad`."
  @spec open(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(
        %{"v" => @version, "alg" => @alg, "kid" => kid, "iv" => iv, "ct" => ct, "tag" => tag},
        aad
      )
      when is_binary(kid) and is_binary(iv) and is_binary(ct) and is_binary(tag) and
             is_binary(aad) do
    with {:ok, key} <- key(kid),
         {:ok, iv} <- b64(iv),
         {:ok, ct} <- b64(ct),
         {:ok, tag} <- b64(tag) do
      decrypt(key, iv, ct, aad, tag)
    end
  end

  def open(_envelope, _aad), do: {:error, :sealed_malformed}

  defp decrypt(key, iv, ct, aad, tag) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
      plain when is_binary(plain) ->
        case Jason.decode(plain) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :sealed_malformed}
        end

      :error ->
        {:error, :sealed_bad_ciphertext}
    end
  end

  defp b64(text) do
    case Base.decode64(text) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :sealed_malformed}
    end
  end

  defp key(kid) do
    with {:ok, keys} <- keys() do
      case Map.get(keys, kid) do
        key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
        _ -> {:error, {:sealed_unknown_key, kid}}
      end
    end
  end

  # The companion is on two channels and holds the key of each: `LLM_SEALED_KEYS` (to the LLM
  # bot, kid k1) and `LETTERS_SEALED_KEYS` (to the 30014 panel, kid letters1). Their kids differ,
  # so one lookup serves both and an envelope can only ever open under its own channel's key.
  defp keys do
    merged =
      Enum.reduce(["LLM_SEALED_KEYS", "LETTERS_SEALED_KEYS"], %{}, fn name, acc ->
        Map.merge(acc, key_set(name))
      end)

    if map_size(merged) == 0, do: {:error, :sealed_key_not_configured}, else: {:ok, merged}
  end

  defp key_set(name) do
    with raw when is_binary(raw) and raw != "" <- BotArmyLibraryRuntime.ConfigLoader.get(name),
         {:ok, %{} = map} <- Jason.decode(raw) do
      Map.new(map, fn {kid, b64} -> {kid, decode_key(b64)} end)
    else
      _ -> %{}
    end
  end

  defp decode_key(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp decode_key(_), do: nil
end
