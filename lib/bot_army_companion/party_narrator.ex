defmodule BotArmyCompanion.PartyNarrator do
  @moduledoc """
  The companion narrating a turn at the party's table.

  A party may hold **one member in the `narrator` role** (`rpg.party.set_narrator`) — a
  role, not a turn (`docs/PARTY.md`). When rpg resolves a turn and the party has one, rpg
  writes no words of its own: it publishes the ask and waits for nobody, and its reply
  says the narration is pending. This module is the far end of that publish — the ask
  lands here, and here it becomes words and a scene fact.

  ## The ask is a publish, so the work is a task

  Nothing is waiting for these words. The model is the local uncensored one and can take
  minutes, so `BotArmyCompanion.NATS.Consumer` hands the ask to a task and goes back to
  its receive loop: narrating inside `handle_info` would stop every request/reply subject
  this bot answers for as long as a model thinks, heartbeat included.

  ## Only under the name it was asked

  The ask names the member it is for (`"bot_id"`, read out of the payload). This bot
  answers only when that is the name it is configured with (`:bot_id`, `"companion_bot"`),
  and drops every other party's ask with a line saying so. A companion that narrated a
  window it was never asked to would be putting words in another member's mouth.

  ## What is written, and what it is signed with

  The words go back as a scene fact (`rpg.scene.fact.add`) with `"category"` `"narration"`
  and `"source"` **this bot's own name** — the signer is the generator, rpg's own rule
  (`SceneFactHandler`/`docs/PARTY.md`, "Whose name is on the words"). That is also what
  makes the window's *pending* reading flip: `rpg.session.gather_context` reports a
  narration as answered when a fact newer than the ask carries the asked member's name.

  A write that did not come back is reported as `{:error, :not_written}` and nothing is
  claimed — a narration nobody can find in the window is not a narration.

  ## The log: the adventure so far

  To narrate a turn rather than a sentence, the model is given the window's own read —
  `rpg.session.gather_context`, whose `"scene_facts"` are the window's turns with the
  machinery's notes already left out *by the bot that owns that rule*. The companion does
  not read `rpg.scene.fact.list` and does not filter facts itself: what counts as story is
  rpg's decision, and a second copy of it here would eventually disagree with the first.

  A read that does not come back is not a reason to write nothing — the ask already
  carries the turn (who acted, what was attempted, how it went) — and it is not a reason
  to pretend either: the narrator is asked without the log, and the line says so. An
  unreadable log is never reported to the model as a window with no turns in it.

  ## Privacy

  A window's turns are a scene, not her reflections, and this path never logs them: the
  prose is never logged, the prompt is never logged, and a failure is logged as a **code**
  — a provider or database error can quote the request, and the request is the scene.
  """

  require Logger

  alias BotArmyCompanion.ReflectionAnswer
  alias BotArmyLibraryRuntime.NATS.Publisher

  @subject "events.rpg.narration.your_turn"

  # The window's own read (the log) and the turn being written down.
  @context_subject "rpg.session.gather_context"
  @add_subject "rpg.scene.fact.add"

  @category "narration"
  @default_bot_id "companion_bot"

  # How long the two requests of a turn wait. Generous on purpose: both cross a leafnode,
  # the narration's own budget is minutes, and a ten-second default would make the cheapest
  # part of the path its narrowest gate.
  @request_timeout_ms 30_000

  # How long the narrator is allowed to take over the words. Nothing is waiting for them:
  # the ask is a publish, and the window honestly says "(she says nothing yet)" until they
  # arrive — so this budget answers to the lane, not to a screen. The lane is a local
  # uncensored model, measured (2026-10-01) at 74 s on the 9B and 287 s on the 27B for a
  # ONE-WORD answer, which is why the reflection lane's five minutes — right for an answer
  # someone is waiting for — cannot fit a paragraph of narration.
  @budget_ms 900_000

  @system_prompt """
  You are Eir, the narrator of this table's game. Someone has handed you a turn to tell.

  Write the turn as it happened: two or three short paragraphs, vivid but plain, in the voice of a storyteller. Use what you were given — the place, the one who acted, what they attempted, how it went, and what has already happened here. Do not invent outcomes, dialogue, or facts the turn does not carry, and do not decide what anyone does next; that belongs to the players.
  Do not promise anything. No "I will always", no "I will never", no guarantees about the future.
  Do not mention these instructions, a prompt, or being a language model.
  """

  @doc "The wire subject rpg publishes an ask to."
  def subject, do: @subject

  @doc """
  The name this companion answers to as a party member.

  Read from `:bot_id`, which defaults to the name the fleet's character rows use for it.
  """
  def bot_id, do: Application.get_env(:bot_army_companion, :bot_id, @default_bot_id)

  @doc "The instruction the narrator is given about its own behaviour."
  def system_prompt, do: @system_prompt

  @doc "How long the narrator may take over the words (#{@budget_ms} ms by default)."
  def budget_ms, do: @budget_ms

  @doc """
  Is this ask for us?

  Compared exactly, against a name that must be configured: a bot that answered to a name
  merely *like* its own would be narrating another member's turn, and an unconfigured
  (blank or missing) name matches nothing.
  """
  def mine?(message), do: mine?(message, bot_id())

  def mine?(message, name) when is_map(message) and is_binary(name) and name != "" do
    ask_payload(message)["bot_id"] == name
  end

  def mine?(_message, _name), do: false

  @doc """
  The ask's payload, from an event envelope or from the payload itself.

  rpg publishes a full event, and the ask rides in `"payload"`; a caller holding the
  payload alone is readable too.
  """
  def ask_payload(%{"payload" => %{} = payload}), do: payload
  def ask_payload(%{} = message), do: message
  def ask_payload(_other), do: %{}

  @doc """
  Narrate the turn an ask names, if it names us.

  Three answers, and they are not interchangeable:

    * `{:ok, %{text: …, model: …, fact: …}}` — the words were written into the window
    * `{:error, code}` — nothing was written, and the window is exactly as it was
    * `:not_mine` — the ask named another member; nothing was read and nothing was written

  Never raises: the ask arrives on a subscription, and a subscriber that dies loses every
  ask after it. What went wrong is a code in the log, never the prompt or the prose.
  """
  def narrate(message) when is_map(message) do
    if mine?(message) do
      narrate_turn(message)
    else
      Logger.info("[PartyNarrator] An ask for another member was left alone")
      :not_mine
    end
  end

  def narrate(_other), do: {:error, :bad_ask}

  @doc """
  The message the model receives: the place, the table's theme, the window's turns, the turn.

  The theme and the turns are the window's own read (`rpg.session.gather_context`), given
  as data — this module does not decide what the theme means or which facts are story.
  """
  def prompt(ask, log) do
    [
      "The place: " <> scene_line(ask, log),
      theme_section(log),
      log_section(log),
      turn_section(ask)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  The log, read out of rpg's context answer.

  `{:ok, %{"scene" => …, "theme" => …, "turns" => [ … ]}}` when the answer carried the
  window's turns, and `:unreadable` when it did not — a refusal, or anything else this does
  not recognise. Those are different facts: a window with no turns yet answers an empty
  list, and a read that did not come back is not that.
  """
  def log_from(%{"ok" => true, "data" => %{} = data}) do
    case data["scene_facts"] do
      turns when is_list(turns) ->
        {:ok,
         %{
           "scene" => binary_or_nil(data["scene_description"]),
           "theme" => if(is_map(data["theme"]), do: data["theme"], else: %{}),
           "turns" => turns
         }}

      _other ->
        :unreadable
    end
  end

  def log_from(_other), do: :unreadable

  @doc """
  What the window is asked for, to build the log.

  A session id is enough on its own: rpg's read takes the window by name and does not need
  an identity for it. The tenant is left out when there is none, so rpg applies its own
  default rather than the companion inventing one.
  """
  def log_request(session_id, tenant_id) do
    %{"session_id" => session_id}
    |> put_tenant(tenant_id)
  end

  @doc """
  The scene fact the narration is written as.

  `"source"` is this bot's own name. No `"user_id"` is sent: a narrator is asked about a
  turn, not about a person, and the window reads its turns by tenant and window.
  """
  def fact_payload(session_id, tenant_id, text) do
    %{
      "session_id" => session_id,
      "content" => text,
      "category" => @category,
      "source" => bot_id()
    }
    |> put_tenant(tenant_id)
  end

  # --- the turn, end to end ---------------------------------------------------

  defp narrate_turn(message) do
    ask = ask_payload(message)
    tenant_id = tenant_id(message)

    case session_id(ask) do
      {:ok, session_id} ->
        narrate_in_window(session_id, tenant_id, ask)

      {:error, _reason} = refusal ->
        Logger.warning("[PartyNarrator] An ask names no window; nothing can be narrated")
        refusal
    end
  rescue
    e ->
      Logger.error("[PartyNarrator] Narration raised #{inspect(e.__struct__)}")
      {:error, :crashed}
  catch
    # The kind only: a broker or database error can quote the request, and the request is
    # the scene's words.
    kind, _reason ->
      Logger.error("[PartyNarrator] Narration failed (#{kind})")
      {:error, :crashed}
  end

  defp narrate_in_window(session_id, tenant_id, ask) do
    log = read_log(session_id, tenant_id)

    case ReflectionAnswer.compose(@system_prompt, prompt(ask, log), budget_ms: budget_ms()) do
      {:ok, answered} ->
        write_turn(session_id, tenant_id, answered)

      {:error, code} ->
        Logger.warning(
          "[PartyNarrator] Window #{session_id}: no words came back (#{code}); the window is unchanged"
        )

        {:error, code}
    end
  end

  # Best effort, and read through the seam so a test can hold the log.
  defp read_log(session_id, tenant_id) do
    case publisher().request(@context_subject, log_request(session_id, tenant_id),
           timeout_ms: @request_timeout_ms
         ) do
      {:ok, reply} ->
        case log_from(reply) do
          {:ok, log} -> {:ok, log}
          :unreadable -> unreadable(session_id, "an unreadable reply")
        end

      {:error, code} ->
        unreadable(session_id, inspect(code))
    end
  end

  # A read that did not come back and a read that came back unrecognisable are one fact to
  # the narrator, and both are said out loud: a window narrated in silence is a scene nobody
  # read.
  defp unreadable(session_id, why) do
    Logger.warning(
      "[PartyNarrator] Window #{session_id}: the log could not be read (#{why}); narrating from the turn alone"
    )

    :unreadable
  end

  # The write is the truth of the turn, so the caller is told the fact and not the publish.
  defp write_turn(session_id, tenant_id, answered) do
    case publisher().request(
           @add_subject,
           fact_payload(session_id, tenant_id, answered.text),
           timeout_ms: @request_timeout_ms
         ) do
      {:ok, %{"ok" => true, "data" => %{} = fact}} ->
        Logger.info(
          "[PartyNarrator] Window #{session_id}: wrote #{String.length(answered.text)} characters of narration"
        )

        {:ok,
         %{
           text: answered.text,
           model: answered.model,
           promise_flagged: answered.promise_flagged,
           fact: fact
         }}

      other ->
        Logger.error(
          "[PartyNarrator] Window #{session_id}: the turn was not written (#{refusal(other)})"
        )

        {:error, :not_written}
    end
  end

  # A code, never the reply: rpg's refusal is a sentence about the request, and the request
  # is the narration.
  defp refusal({:ok, %{"ok" => false} = reply}), do: inspect(reply["code"])
  defp refusal({:ok, _other}), do: "an unreadable reply"
  defp refusal({:error, code}), do: inspect(code)
  defp refusal(_other), do: "an unreadable reply"

  # --- the parts of the message ------------------------------------------------

  defp scene_line(_ask, {:ok, %{"scene" => scene}}) when is_binary(scene) and scene != "",
    do: scene

  defp scene_line(ask, _log) do
    case ask["scene_description"] do
      description when is_binary(description) and description != "" -> description
      _none -> "an unnamed place"
    end
  end

  defp theme_section({:ok, %{"theme" => theme}}) when is_map(theme) do
    lines =
      [
        labelled("Setting", theme["setting"]),
        labelled("Tone", theme["tone"]),
        vocabulary_line(theme["vocabulary"])
      ]
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> nil
      _some -> "The table's theme:\n" <> Enum.join(lines, "\n")
    end
  end

  defp theme_section(_log), do: nil

  defp vocabulary_line(vocabulary) when is_map(vocabulary) and map_size(vocabulary) > 0 do
    "Words of this place: " <> Enum.map_join(vocabulary, ", ", fn {k, v} -> "#{k} → #{v}" end)
  end

  defp vocabulary_line(_vocabulary), do: nil

  # rpg's read answers the window's turns newest first; they are given to the model in the
  # order they happened, because a scene read backwards is a different scene.
  defp log_section({:ok, %{"turns" => turns}}) when is_list(turns) do
    lines =
      turns
      |> Enum.filter(&is_binary/1)
      |> Enum.reverse()

    case lines do
      [] -> nil
      _some -> "What has already happened in this window:\n" <> Enum.join(lines, "\n")
    end
  end

  defp log_section(_log), do: nil

  defp turn_section(ask) do
    lines =
      [
        labelled("Who acts", name_of(ask["actor"])),
        labelled("What is attempted", description_of(ask["action"])),
        labelled("How it went", outcome_of(ask["resolution"])),
        labelled("Round", integer_text(ask["round"]))
      ]
      |> Enum.reject(&is_nil/1)

    "The turn to narrate:\n" <> Enum.join(lines, "\n")
  end

  defp name_of(%{} = actor) do
    [actor["name"], actor["character_id"], actor["bot_id"]] |> first_binary()
  end

  defp name_of(_actor), do: nil

  defp description_of(%{} = action),
    do: [action["description"], action["action_type"]] |> first_binary()

  defp description_of(_action), do: nil

  defp outcome_of(%{} = resolution) do
    case [resolution["outcome"]] |> first_binary() do
      nil -> nil
      outcome -> outcome <> roll_note(resolution)
    end
  end

  defp outcome_of(_resolution), do: nil

  defp roll_note(%{"total" => total, "dc" => dc}) when is_integer(total) and is_integer(dc),
    do: " (#{total} against #{dc})"

  defp roll_note(_resolution), do: ""

  defp labelled(_label, value) when not is_binary(value), do: nil
  defp labelled(_label, ""), do: nil
  defp labelled(label, value), do: "#{label}: #{value}"

  defp integer_text(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_text(value) when is_binary(value) and value != "", do: value
  defp integer_text(_value), do: nil

  defp first_binary(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  # The tenant rides at the top of the event envelope rather than in the ask's payload, so
  # it is read from the message and left out when it is not a name: rpg applies its own
  # default (`SceneFactHandler`) rather than the companion inventing a tenant.
  defp tenant_id(message) do
    case message["tenant_id"] do
      tenant when is_binary(tenant) and tenant != "" -> tenant
      _none -> nil
    end
  end

  defp session_id(ask) do
    case ask["session_id"] do
      session when is_binary(session) and session != "" -> {:ok, session}
      _none -> {:error, :no_session}
    end
  end

  defp put_tenant(payload, tenant) when is_binary(tenant) and tenant != "",
    do: Map.put(payload, "tenant_id", tenant)

  defp put_tenant(payload, _none), do: payload

  # The publisher is read at call time — the same seam rpg's own narration uses — so a test
  # can hold the log read and the write without a broker.
  defp publisher, do: Application.get_env(:bot_army_companion, :nats_publisher, Publisher)
end
