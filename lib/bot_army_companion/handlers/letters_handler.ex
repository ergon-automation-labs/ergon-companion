defmodule BotArmyCompanion.Handlers.LettersHandler do
  @moduledoc """
  The two doors to the pen-pal thread: `companion.letters.send` and `companion.letters.thread`.

  Every request arrives sealed, and the answer leaves sealed:

      request   %{"request_id" => rid, "sealed" => envelope}     envelope opens to the real fields
      answer    %{"request_id" => rid, "sealed" => envelope}     envelope opens to the data

  The envelope is the only authentication there is. NATS is a flat bus: any process that can reach
  it can publish to these subjects, and the panel's own token cannot be checked here. What it can
  be checked for is the one thing only the 30014 panel and this bot hold: the letters channel's key
  (`BotArmyCompanion.Sealed.letters_kid/0`). So a request that is not sealed, is sealed under
  another channel's key, is bound to another request id, or was sealed for the LLM bot, is refused
  with one code and no detail (`:bad_seal`), before `Letters` is asked anything. The 30013 panel
  has no such key, so even a rogue request from there cannot read or write a letter.

  Refusals carry fixed words and a code. They never echo what the sender wrote.
  """

  alias BotArmyCompanion.{Letters, Sealed}

  @send_subject "companion.letters.send"
  @thread_subject "companion.letters.thread"

  @doc "The subjects this handler answers."
  @spec subjects() :: [String.t()]
  def subjects, do: [@send_subject, @thread_subject]

  @doc """
  Answer one request. `{:ok, sealed_reply_map}` or `{:error, code, message}`.

  `opts[:letters]` swaps the store (a test passes a fake), `opts[:now]` the clock.
  """
  @spec handle(String.t(), term(), keyword()) :: {:ok, map()} | {:error, atom(), String.t()}
  def handle(subject, body, opts \\ [])

  def handle(subject, body, opts) when subject in [@send_subject, @thread_subject] do
    letters = Keyword.get(opts, :letters, Letters)

    with {:ok, rid, inner} <- open(body),
         {:ok, data} <- run(subject, inner, rid, letters, opts) do
      seal(rid, data)
    end
  end

  def handle(_subject, _body, _opts),
    do: {:error, :unknown_subject, "that is not a letters subject"}

  # -- the seal --------------------------------------------------------------------------

  defp open(%{"request_id" => rid, "sealed" => %{"kid" => kid} = env})
       when is_binary(rid) and rid != "" do
    with true <- kid == Sealed.letters_kid() || :bad_seal,
         {:ok, inner} <- Sealed.open(env, Sealed.letters_aad(:request, rid)) do
      {:ok, rid, inner}
    else
      _ -> {:error, :bad_seal, "that request could not be opened"}
    end
  end

  defp open(_unsealed), do: {:error, :unsealed, "letters only travel sealed"}

  defp seal(rid, data) do
    case Sealed.seal(data, Sealed.letters_kid(), Sealed.letters_aad(:response, rid)) do
      {:ok, env} -> {:ok, %{"request_id" => rid, "sealed" => env}}
      {:error, _} -> {:error, :unavailable, "letters are not set up on this node"}
    end
  end

  # -- the doors -------------------------------------------------------------------------

  defp run(@send_subject, inner, rid, letters, opts) do
    case letters.send_letter(inner["text"], rid, now: opts[:now]) do
      {:ok, result, state} -> {:ok, Map.put(result, "duplicate", state == :existing)}
      {:error, reason} -> refusal(reason)
    end
  end

  defp run(@thread_subject, inner, _rid, letters, opts) do
    limit = if is_integer(inner["limit"]), do: inner["limit"], else: 40

    case letters.thread(limit: limit, now: opts[:now]) do
      {:ok, views} -> {:ok, %{"letters" => views}}
      {:error, reason} -> refusal(reason)
    end
  end

  # Fixed words, mapped from the store's reasons. Nothing the sender wrote comes back.
  defp refusal(:no_text), do: {:error, :validation_error, "a letter needs words in it"}

  defp refusal({:too_long, max}),
    do: {:error, :validation_error, "a letter can be up to #{max} characters"}

  defp refusal(:needs_request_id), do: {:error, :validation_error, "a request id is required"}
  defp refusal(:invalid), do: {:error, :validation_error, "the store refused that letter"}
  defp refusal(:store_unavailable), do: {:error, :unavailable, "the letters could not be reached"}

  defp refusal(reason) when reason in [:sealed_key_not_configured],
    do: {:error, :unavailable, "letters are not set up on this node"}

  defp refusal(_other), do: {:error, :unavailable, "the letters could not be reached"}
end
