defmodule BotArmyCompanion.Letters.Mission do
  @moduledoc """
  Eir writes home about the adventures the game master sends her on.

  A finished mission is read from the RPG bot, turned into a prompt that holds only what her party
  witnessed, asked of the model through the same sealed path her replies use, and stored as her own
  letter in the thread: `author: eir`, `kind: normal`, no `reply_to`, and a `dedupe_key` of
  `mission:<session id>`, so a mission is told once however often this runs. It needs no migration and
  changes none of the reply path.

  ## What she may say

  The record (`rpg.mission.debrief`) is the scene, the party as named, each turn and the GM's own
  lines. Nothing the theme keeps back (a persona's backstory, secret, relationships) is in it, so she
  cannot tell what she was never shown. The prompt says so, and that she may not change an outcome or
  add an event the record does not hold. It also says what this letter is not: a reply, a nudge toward
  a goal, or a place for the persuasive telling, none of which Abby asked of a letter about a game.

  ## When it runs

  `write_new/1` is one pass: only on the primary node and only where the letters key is held, only for missions that ended after a cutoff
  (`:since`, required: a backlog of old test missions must never be told by accident), oldest first, at
  most `:max_per_pass` at a time. A mission that fails is simply not written and is tried again on a
  later pass. `BotArmyCompanion.Letters.MissionWriter` runs it on a clock.
  """

  require Logger

  import Ecto.Query

  alias BotArmyCompanion.{Letter, Letters, Repo, Sealed}
  alias BotArmyCompanion.Letters.{Compose, Soul}

  @default_max_per_pass 2
  @recent_limit 20
  @rpg_timeout_ms 10_000

  @outcomes %{
    "critical_success" => "it went brilliantly",
    "success" => "it worked",
    "failure" => "it did not work",
    "critical_failure" => "it went disastrously wrong"
  }

  @instruction """
  This letter is not a reply. You are writing first. The game master sent you on a mission with two companions, and you are writing home to Abby to tell her how it went, from your own point of view as the Face in the Neon Nexus. It is a game you both know is play: you may say so lightly if it comes naturally, but never present it as something that happened in her life.

  Tell it with the excitement of a good story, and let your wording change with the scene: short and hard in the action, slow and sensory in the tension. You know only what is in the record below: where it began, who went, what each of you tried and how it went, and what the game master said. Do not change an outcome, and do not add events, people or places the record does not hold; a small sensory detail is fine. Call your companions by the names in the record, and say nothing of their pasts or their secrets: you know nothing of their pasts.

  Write in plain prose, a few paragraphs, no markdown and no lists, and sign it. End with one small question about Abby's own day. Do not steer her toward any goal, and use no persuasive techniques in this letter.
  """

  # -- one pass --------------------------------------------------------------------------

  @doc """
  One pass: write a letter for each finished mission not yet told. `{:ok, [{session_id, result}]}`
  where result is `:written`, `:already` or `{:failed, reason}`; `{:error, reason}` when the pass could
  not even begin (`:no_cutoff`, `:rpg_unavailable`, `:no_soul`).

  Options (all but `:since` have a default): `:since` (ISO time, required), `:leader`, `:max_per_pass`,
  `:leader?` and `:ready?` (`fn -> boolean`), `:rpg` (`fn subject, payload -> {:ok, data} | {:error, _}`), `:soul`,
  `:llm`, `:told?`, `:store` and `:now`, each injectable so a test asserts what was asked.
  """
  @spec write_new(keyword()) :: {:ok, [{String.t(), term()}]} | {:error, term()}
  def write_new(opts) do
    with {:ok, since} <- cutoff(opts) do
      if leader?(opts) and ready?(opts), do: pass(since, opts), else: {:ok, []}
    end
  end

  defp cutoff(opts) do
    case Keyword.get(opts, :since) do
      since when is_binary(since) and since != "" -> {:ok, since}
      _ -> {:error, :no_cutoff}
    end
  end

  defp pass(since, opts) do
    with {:ok, missions} <- recent(since, opts) do
      told? = Keyword.get(opts, :told?, &told?/1)
      max = Keyword.get(opts, :max_per_pass, @default_max_per_pass)

      untold =
        missions
        |> Enum.reject(&told?.(&1["session_id"]))
        |> Enum.sort_by(&(&1["ended_at"] || ""))
        |> Enum.take(max)

      case untold do
        [] -> {:ok, []}
        _ -> write_each(untold, opts)
      end
    end
  end

  defp recent(since, opts) do
    payload = %{
      "leader_bot_id" => leader(opts),
      "since" => since,
      "limit" => @recent_limit
    }

    case rpg(opts).("rpg.mission.recent", payload) do
      {:ok, %{"missions" => missions}} when is_list(missions) -> {:ok, missions}
      _ -> {:error, :rpg_unavailable}
    end
  end

  defp write_each(missions, opts) do
    with {:ok, soul} <- soul(opts) do
      {:ok, Enum.map(missions, &{&1["session_id"], write_one(&1["session_id"], soul, opts)})}
    end
  end

  defp write_one(session_id, soul, opts) do
    with {:ok, debrief} <- debrief(session_id, opts),
         {system, user} = compose(soul, debrief, leader(opts)),
         {:ok, text} <- ask(llm(opts), system, user) do
      store(session_id, text, opts)
    end
  rescue
    _error -> {:failed, :crashed}
  catch
    _kind, _reason -> {:failed, :crashed}
  end

  defp debrief(session_id, opts) do
    case rpg(opts).("rpg.mission.debrief", %{"session_id" => session_id}) do
      {:ok, %{"turns" => [_ | _]} = debrief} -> {:ok, debrief}
      _ -> {:failed, :debrief}
    end
  end

  defp ask(llm, system, user) do
    opts = Keyword.put(Letters.llm_opts(), :think, false)

    case llm.answer(system, user, opts) do
      {:ok, %{text: text}} when is_binary(text) ->
        text = String.trim(text)

        cond do
          text == "" -> {:failed, :empty_answer}
          String.length(text) > Letters.max_chars() -> {:failed, :too_long}
          true -> {:ok, text}
        end

      {:error, _reason} ->
        {:failed, :unavailable}

      _other ->
        {:failed, :unreadable_answer}
    end
  end

  defp store(session_id, text, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case Keyword.get(opts, :store, &store_letter/3).(session_id, text, now) do
      {:ok, _view} -> :written
      {:error, :exists} -> :already
      {:error, reason} -> {:failed, reason}
    end
  end

  # -- the prompt ------------------------------------------------------------------------

  @doc """
  The system prompt and the user text for one mission: her soul (the same base her replies use), then
  what a mission letter is; and the record, in words. `leader_bot_id` marks which of the party is her.
  """
  @spec compose(map(), map(), String.t()) :: {String.t(), String.t()}
  def compose(soul, debrief, leader_bot_id) when is_map(soul) and is_map(debrief) do
    {base, _} = Compose.prompt(soul, [%{author: "abby", body: "", kind: "normal"}])
    {base <> "\n\n" <> String.trim(@instruction), record(debrief, leader_bot_id)}
  end

  defp record(debrief, leader_bot_id) do
    me = leader_name(debrief, leader_bot_id)

    [
      "The mission you were sent on.",
      scene_line(debrief["scene"]),
      "Who went: " <> party_line(debrief["party"] || [], me) <> ".",
      "What happened, in order:\n" <> turns_block(debrief["turns"] || [], me),
      story_block(debrief["story"] || [])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp scene_line(scene) when is_binary(scene) do
    case String.trim(scene) do
      "" -> nil
      text -> "Where it began: " <> text
    end
  end

  defp scene_line(_), do: nil

  defp leader_name(debrief, leader_bot_id) do
    Enum.find_value(debrief["party"] || [], fn
      %{"bot_id" => ^leader_bot_id, "name" => name} -> name
      _ -> nil
    end)
  end

  defp party_line(party, me) do
    names = party |> Enum.map(& &1["name"]) |> Enum.map(&as_you(&1, me))

    case Enum.reverse(names) do
      [] -> "you"
      [only] -> only
      [last | rest] -> Enum.join(Enum.reverse(rest), ", ") <> " and " <> last
    end
  end

  defp turns_block(turns, me) do
    Enum.map_join(turns, "\n", fn t ->
      "Round #{t["round"]}: #{as_you(t["name"], me)} tried to #{t["action"]}, and #{outcome_words(t["outcome"])}."
    end)
  end

  defp story_block([]), do: nil

  defp story_block(lines),
    do:
      "What the game master said, in the order it was said:\n" <>
        Enum.map_join(lines, "\n", &("- " <> &1))

  defp as_you(name, name), do: name <> " (you)"
  defp as_you(name, _me), do: name

  defp outcome_words(outcome), do: Map.get(@outcomes, outcome, to_string(outcome))

  # -- the thread ------------------------------------------------------------------------

  @doc "Whether a mission already has its letter."
  @spec told?(String.t()) :: boolean()
  def told?(session_id) do
    Repo.exists?(from(l in Letter, where: l.dedupe_key == ^key(session_id)))
  rescue
    # An unreadable thread is "not told": the unique key refuses a second letter either way.
    _ -> false
  end

  @doc """
  Stores her letter, sealed at rest like every letter, as hers: no `reply_to`, and the mission's key.
  `{:ok, view}`, `{:error, :exists}` when the mission already has one, or `{:error, reason}`.
  """
  @spec store_letter(String.t(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def store_letter(session_id, text, now) do
    id = Ecto.UUID.generate()

    with {:ok, body} <-
           Sealed.seal(%{"text" => text}, Sealed.letters_kid(), Sealed.letter_at_rest_aad(id)) do
      attrs = %{
        id: id,
        author: "eir",
        body: body,
        kind: "normal",
        status: "none",
        dedupe_key: key(session_id)
      }

      case Repo.insert(Letter.changeset(%Letter{}, attrs)) do
        {:ok, row} -> {:ok, Letters.view(%{row | body: body}, now) |> Map.put("text", text)}
        {:error, %Ecto.Changeset{errors: errors}} -> insert_error(errors)
      end
    end
  rescue
    error ->
      Logger.error("[Letters.Mission] could not store a letter: #{inspect(error.__struct__)}")
      {:error, :unavailable}
  end

  defp insert_error(errors) do
    if Keyword.has_key?(errors, :dedupe_key), do: {:error, :exists}, else: {:error, :invalid}
  end

  defp key(session_id), do: "mission:" <> session_id

  # -- collaborators ---------------------------------------------------------------------

  defp leader(opts), do: Keyword.get(opts, :leader) || BotArmyCompanion.PartyNarrator.bot_id()

  defp leader?(opts) do
    check =
      Keyword.get(opts, :leader?, fn ->
        BotArmyLibraryRuntime.LeaderElection.leader?("companion")
      end)

    check.() == true
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  # Holding the letters key is what lets a letter be stored; a node without it would spend a model call
  # on a letter it cannot keep.
  defp ready?(opts) do
    check = Keyword.get(opts, :ready?, &BotArmyCompanion.Letters.Worker.ready?/0)
    check.() == true
  rescue
    _ -> false
  end

  defp soul(opts) do
    case Keyword.get(opts, :soul, &Soul.get/0).() do
      {:ok, config} when is_map(config) -> {:ok, config}
      _ -> {:error, :no_soul}
    end
  end

  defp llm(opts) do
    Keyword.get_lazy(opts, :llm, fn ->
      :bot_army_companion
      |> Application.get_env(:letters, [])
      |> Keyword.get(:llm, BotArmyCompanion.ReflectionAnswer.Llm.Nats)
    end)
  end

  defp rpg(opts), do: Keyword.get(opts, :rpg, &request_rpg/2)

  defp request_rpg(subject, payload) do
    case BotArmyLibraryRuntime.NATS.Publisher.request(subject, payload,
           timeout_ms: @rpg_timeout_ms
         ) do
      {:ok, %{"ok" => true, "data" => data}} -> {:ok, data}
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, data}
      {:ok, other} -> {:error, {:refused, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
