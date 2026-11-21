defmodule BotArmyCompanion.Letters do
  @moduledoc """
  The pen-pal thread between Abby and Eir: sending a letter, reading the thread, and the work of
  writing a reply.

  ## What a send does

  `send_letter/3` stores Abby's letter sealed at rest and decides what happens next:

    * **A crisis letter** (`Letters.Compose.crisis?/1`) is answered at once with the fixed safety
      reply, in the same transaction, and no model is asked. It does not ride the pen-pal delay: a
      2 a.m. letter that worried her gets the reply at 2 a.m., not at 07:30.
    * **Any other letter** waits for its reply (`Letters.Timing.deliver_at/1`): the next morning
      for an evening or overnight one, a few hours for a daytime one.

  A repeat of the same `request_id` finds the first letter instead of making a second one, so a
  double tap, a reconnect or a replayed request cannot cost a second model call.

  ## What delivery does

  `claim_due/1` takes every waiting letter whose time has come in one atomic `UPDATE ... RETURNING`
  (`FOR UPDATE SKIP LOCKED`), so a restart or a second node cannot write two replies. `deliver/2`
  answers the claimed letters, and any earlier one that failed, together as one reply, with the soul
  as the system prompt, through the sealed LLM path. A missing soul or a model that cannot answer
  marks the letters `failed`; nothing is lost, and the next letter's reply picks them up.

  Nothing here counts unread letters or measures how long it has been since she wrote.
  """

  require Logger

  import Ecto.Query

  alias BotArmyCompanion.{Letter, Repo, Sealed}
  alias BotArmyCompanion.Letters.{Compose, Soul, Timing}

  @max_chars 8_000
  @thread_limit 40
  @stale_writing_s 20 * 60

  @type view :: %{String.t() => term()}

  @doc "The longest letter, in characters."
  def max_chars, do: @max_chars

  # -- sending ---------------------------------------------------------------------------

  @doc """
  Store Abby's letter. `{:ok, %{"letter" => view, "reply" => view | nil}, :created | :existing}`.

  `reply` is the safety reply for a crisis letter and `nil` otherwise. A letter that is empty, too
  long, has no usable `request_id`, or cannot be sealed (no key) is refused, and nothing is stored.
  """
  @spec send_letter(term(), term(), keyword()) ::
          {:ok, %{String.t() => view() | nil}, :created | :existing} | {:error, term()}
  def send_letter(text, request_id, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, text} <- take_text(text),
         {:ok, key} <- take_key(request_id) do
      safely(fn -> first_or_create(text, key, now) end)
    end
  end

  defp first_or_create(text, key, now) do
    case Repo.get_by(Letter, dedupe_key: key) do
      %Letter{} = first -> {:ok, sent(first, now), :existing}
      nil -> create(text, key, now)
    end
  end

  defp take_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :no_text}
      String.length(text) > @max_chars -> {:error, {:too_long, @max_chars}}
      true -> {:ok, text}
    end
  end

  defp take_text(_), do: {:error, :no_text}

  defp take_key(key) when is_binary(key) do
    if String.trim(key) == "", do: {:error, :needs_request_id}, else: {:ok, key}
  end

  defp take_key(_), do: {:error, :needs_request_id}

  defp create(text, key, now) do
    id = Ecto.UUID.generate()
    crisis? = Compose.crisis?(text)

    with {:ok, body} <- seal_body(id, text) do
      attrs = %{
        id: id,
        author: "abby",
        body: body,
        kind: "normal",
        status: if(crisis?, do: "answered", else: "waiting"),
        dedupe_key: key,
        deliver_at: if(crisis?, do: now, else: Timing.deliver_at(now))
      }

      if crisis?, do: create_with_safety(attrs, now), else: create_waiting(attrs, key, now)
    end
  end

  defp create_waiting(attrs, key, now) do
    case Repo.insert(Letter.changeset(%Letter{}, attrs)) do
      {:ok, row} -> {:ok, sent(row, now), :created}
      {:error, changeset} -> collided_or_invalid(changeset, key, now)
    end
  end

  defp create_with_safety(attrs, now) do
    safety_id = Ecto.UUID.generate()

    with {:ok, safety_body} <- seal_body(safety_id, Compose.safety_reply()) do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:abby, Letter.changeset(%Letter{}, attrs))
        |> Ecto.Multi.insert(
          :eir,
          Letter.changeset(%Letter{}, %{
            id: safety_id,
            author: "eir",
            body: safety_body,
            reply_to_id: attrs.id,
            kind: "safety",
            status: "none"
          })
        )

      case Repo.transaction(multi) do
        {:ok, %{abby: row}} -> {:ok, sent(row, now), :created}
        {:error, :abby, changeset, _} -> collided_or_invalid(changeset, attrs.dedupe_key, now)
        {:error, _step, _changeset, _} -> {:error, :invalid}
      end
    end
  end

  # Under a race the first writer's row is the answer, whichever writer wrote it.
  defp collided_or_invalid(changeset, key, now) do
    if Keyword.has_key?(changeset.errors, :dedupe_key) do
      case Repo.get_by(Letter, dedupe_key: key) do
        %Letter{} = first -> {:ok, sent(first, now), :existing}
        nil -> {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

  defp sent(%Letter{} = abby, now) do
    reply =
      Repo.one(
        from(l in Letter,
          where: l.reply_to_id == ^abby.id and l.author == "eir" and l.kind == "safety",
          limit: 1
        )
      )

    %{"letter" => view(abby, now), "reply" => reply && view(reply, now)}
  end

  # -- reading ---------------------------------------------------------------------------

  @doc "The recent thread, oldest first. `{:ok, [view]}`."
  @spec thread(keyword()) :: {:ok, [view()]} | {:error, :store_unavailable}
  def thread(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    limit = opts |> Keyword.get(:limit, @thread_limit) |> min(@thread_limit) |> max(1)

    safely(fn ->
      rows =
        from(l in Letter, order_by: [desc: l.inserted_at, desc: l.id], limit: ^limit)
        |> Repo.all()
        |> Enum.reverse()

      {:ok, Enum.map(rows, &view(&1, now))}
    end)
  end

  @doc """
  One letter as the panel shows it: its words (opened here), who wrote it, when, and where its
  reply stands. `felt` is felt time ("tomorrow morning"), never a timestamp, and only for a letter
  still waiting. A body that will not open has `"text" => nil` rather than an error.
  """
  @spec view(Letter.t(), DateTime.t()) :: view()
  def view(%Letter{} = l, now) do
    base = %{
      "id" => l.id,
      "author" => l.author,
      "kind" => l.kind,
      "text" => open_body(l),
      "at" => DateTime.to_iso8601(l.inserted_at),
      "status" => l.status
    }

    if l.status == "waiting" and l.deliver_at,
      do: Map.put(base, "felt", Timing.felt(l.deliver_at, now)),
      else: base
  end

  # -- delivery --------------------------------------------------------------------------

  @doc """
  Atomically claim every waiting letter that is due. Returns their ids (empty when none).

  One `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING`: two workers racing
  split nothing and double-claim nothing.
  """
  @spec claim_due(DateTime.t()) :: [String.t()]
  def claim_due(%DateTime{} = now) do
    due =
      from(l in Letter,
        where: l.author == "abby" and l.status == "waiting" and l.deliver_at <= ^now,
        select: l.id,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    {_n, rows} =
      from(l in Letter, where: l.id in subquery(due), select: l.id)
      |> Repo.update_all(set: [status: "writing", updated_at: now])

    rows
  end

  @doc """
  Put letters a worker claimed and then abandoned (a crash, a restart) back to waiting. They have
  been `writing` for longer than a model is allowed to take.
  """
  @spec reclaim_stale(DateTime.t()) :: non_neg_integer()
  def reclaim_stale(%DateTime{} = now) do
    cutoff = DateTime.add(now, -@stale_writing_s, :second)

    {n, _} =
      from(l in Letter, where: l.status == "writing" and l.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "waiting", updated_at: now])

    n
  end

  @doc """
  Write one reply to the claimed letters (and any earlier one that failed), together.

  Options (all injectable so no broker or model is needed to test it): `:soul` (a 0-arity fun),
  `:llm` (a module with `answer/3`), `:now`. Returns `{:ok, view}` for Eir's new letter, or
  `{:error, reason}` after marking the claimed letters `failed`.
  """
  @spec deliver([String.t()], keyword()) :: {:ok, view()} | {:error, term()}
  def deliver([], _opts), do: {:error, :nothing_to_deliver}

  def deliver(ids, opts) when is_list(ids) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    soul = Keyword.get(opts, :soul, &Soul.get/0)
    llm = Keyword.get(opts, :llm) || llm_module()

    case write_reply(ids, soul, llm, now) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        mark_failed(ids, now)
        {:error, reason}
    end
  rescue
    e ->
      # The struct, never the message: a provider's message can quote the request.
      Logger.error("[Letters] delivery crashed (#{inspect(e.__struct__)})")
      mark_failed(ids, Keyword.get(opts, :now) || DateTime.utc_now())
      {:error, :crashed}
  end

  # The soul, the thread, the model, the store: each step can refuse, and a refusal is the answer.
  defp write_reply(ids, soul, llm, now) do
    with {:ok, config} <- soul.(),
         {:ok, thread, cutoff, last_id} <- prompt_thread(ids),
         {system, user} = Compose.prompt(config, thread),
         {:ok, %{text: text}} <- ask(llm, system, user) do
      store_reply(last_id, cutoff, text, now)
    end
  end

  defp ask(llm, system, user) do
    case llm.answer(system, user, llm_opts()) do
      {:ok, %{text: text} = answer} when is_binary(text) ->
        if String.trim(text) == "", do: {:error, :empty_answer}, else: {:ok, answer}

      {:error, code} when is_atom(code) ->
        {:error, code}

      _ ->
        {:error, :model_failed}
    end
  end

  # The thread up to the newest claimed letter, oldest first, opened. Letters that arrived after
  # the claim wait for their own reply. A claimed letter that will not open stops delivery: a
  # reply to words nobody could read would be a reply to nothing.
  defp prompt_thread(ids) do
    batch = Repo.all(from(l in Letter, where: l.id in ^ids, order_by: [asc: l.inserted_at]))

    case List.last(batch) do
      nil -> {:error, :not_found}
      last -> thread_up_to(last, Enum.any?(batch, &(open_body(&1) == nil)))
    end
  end

  defp thread_up_to(_last, true = _unreadable), do: {:error, :unreadable}

  defp thread_up_to(last, false) do
    thread =
      from(l in Letter,
        where: l.inserted_at <= ^last.inserted_at,
        order_by: [desc: l.inserted_at, desc: l.id],
        limit: ^@thread_limit
      )
      |> Repo.all()
      |> Enum.reverse()
      |> Enum.flat_map(&prompt_letter/1)

    {:ok, thread, last.inserted_at, last.id}
  end

  # A letter that will not open is left out of the history rather than guessed at.
  defp prompt_letter(%Letter{} = l) do
    case open_body(l) do
      nil -> []
      text -> [%{author: l.author, body: text, kind: l.kind}]
    end
  end

  defp store_reply(last_id, cutoff, text, now) do
    id = Ecto.UUID.generate()

    with {:ok, body} <- seal_body(id, text) do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :eir,
          Letter.changeset(%Letter{}, %{
            id: id,
            author: "eir",
            body: body,
            reply_to_id: last_id,
            kind: "normal",
            status: "none"
          })
        )
        |> Ecto.Multi.update_all(
          :answered,
          from(l in Letter,
            where:
              l.author == "abby" and l.status in ["writing", "failed"] and
                l.inserted_at <= ^cutoff
          ),
          set: [status: "answered", updated_at: now]
        )

      case Repo.transaction(multi) do
        {:ok, %{eir: row}} -> {:ok, view(row, now)}
        {:error, _step, _changeset, _} -> {:error, :store_failed}
      end
    end
  end

  defp mark_failed(ids, now) do
    from(l in Letter, where: l.id in ^ids and l.status == "writing")
    |> Repo.update_all(set: [status: "failed", updated_at: now])
  rescue
    _ -> :ok
  end

  @doc """
  The request the model gets: the uncensored light tier, sealed. Sealing is not configurable here:
  a letter never goes to the model in plain text. Pillar-level overrides (`:letters, :llm_opts`)
  can change patience and limits, never `:seal`.
  """
  @spec llm_opts() :: keyword()
  def llm_opts do
    overrides =
      :bot_army_companion |> Application.get_env(:letters, []) |> Keyword.get(:llm_opts, [])

    [
      subject: "llm.request.chat",
      status_subject: "llm.job.status",
      model_type: "uncensored",
      uncensored_tier: "light",
      lane: "background",
      max_tokens: 1_200,
      budget_ms: 1_800_000,
      poll_ms: 10_000,
      submit_timeout_ms: 20_000,
      status_timeout_ms: 30_000
    ]
    |> Keyword.merge(overrides)
    |> Keyword.put(:seal, true)
  end

  defp llm_module do
    :bot_army_companion
    |> Application.get_env(:letters, [])
    |> Keyword.get(:llm, BotArmyCompanion.ReflectionAnswer.Llm.Nats)
  end

  # -- sealing at rest -------------------------------------------------------------------

  defp seal_body(id, text) do
    Sealed.seal(%{"text" => text}, Sealed.letters_kid(), Sealed.letter_at_rest_aad(id))
  end

  defp open_body(%Letter{id: id, body: body}) do
    case Sealed.open(body, Sealed.letter_at_rest_aad(id)) do
      {:ok, %{"text" => text}} when is_binary(text) -> text
      _ -> nil
    end
  end

  # A store that is down is a state the caller has a word for, not a crash, and the message of a
  # database error can quote a value, so only the exception's module is logged.
  defp safely(fun) do
    fun.()
  rescue
    e ->
      Logger.error("[Letters] store failed (#{inspect(e.__struct__)})")
      {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :store_unavailable}
  end
end
