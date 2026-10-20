defmodule BotArmyCompanion.NATS.ConsumerSubjectsTest do
  @moduledoc """
  What the consumer advertises, and what it therefore listens to.

  This file exists because of a specific failure: the dashboard's two reflect
  screens published `events.reflection.captured` and **nothing anywhere
  subscribed to it**, so her words were dropped by core NATS while the screen
  said "captured". "Somebody is listening" is not a thing you can check by
  reading a screen, so it is checked here.
  """

  use ExUnit.Case, async: true

  @moduletag :nats

  alias BotArmyCompanion.NATS.Consumer

  # The subjects the consumer carried before her reflections had a home. Listed
  # explicitly (rather than counted) so adding a subject never rewrites this
  # test into a lie, and removing one cannot pass unnoticed.
  @already_advertised ~w(
    companion.heartbeat
    companion.reflection
    companion.observations.list
    companion.observations.read
    companion.observations.reply
    companion.presence
  )

  test "every subject the consumer used to carry is still advertised" do
    advertised = Enum.map(Consumer.subjects(), & &1.subject)

    for subject <- @already_advertised do
      assert subject in advertised
    end
  end

  test "her captured reflections are advertised, on both paths in" do
    advertised = Enum.map(Consumer.subjects(), & &1.subject)

    for subject <- ~w(
         companion.reflections.capture
         companion.reflections.list
         companion.reflections.read
         events.reflection.captured
       ) do
      assert subject in advertised
    end
  end

  test "the reflect screen's subject is a subscription, not just a label" do
    # `business_subjects/0` is derived from `subjects/0` — the same list the
    # primary node subscribes to on connect — so membership here means the
    # consumer actually listens on it.
    assert "events.reflection.captured" in Consumer.business_subjects()
    assert "companion.reflections.capture" in Consumer.business_subjects()
    assert "companion.reflections.list" in Consumer.business_subjects()
    assert "companion.reflections.read" in Consumer.business_subjects()
  end

  test "nothing is advertised without being subscribed to" do
    advertised = Enum.map(Consumer.subjects(), & &1.subject)

    assert Enum.sort(Consumer.business_subjects()) == Enum.sort(advertised)
  end

  test "the two arrivals that carry bare JSON are marked as pubsub, not request/reply" do
    types = Map.new(Consumer.subjects(), &{&1.subject, &1.type})

    assert types["events.reflection.captured"] == :pubsub
    assert types["companion.presence"] == :pubsub
    assert types["companion.reflections.capture"] == :request_reply
  end

  test "the llm bot's bell is advertised, and subscribed to" do
    # The bell is what ends an hour-long wait for a slow local model. A subject
    # that is advertised but never subscribed to is the failure this whole file
    # exists for: the llm bot would ring, nobody would hear it, and every waiter
    # would fall back to asking on its own cadence without anyone knowing why.
    advertised = Enum.map(Consumer.subjects(), & &1.subject)

    assert "events.llm.job.completed" in advertised
    assert "events.llm.job.completed" in Consumer.business_subjects()
    refute "llm.job.completed" in advertised
  end

  test "the party's ask is advertised on the wire subject rpg actually publishes" do
    # rpg derives `events.rpg.narration.your_turn` from its event name; a
    # subscription written as the event name would be a subject nobody publishes
    # to, and the turn would be handed to a narrator that never hears it.
    advertised = Enum.map(Consumer.subjects(), & &1.subject)

    assert "events.rpg.narration.your_turn" in advertised
    assert "events.rpg.narration.your_turn" in Consumer.business_subjects()
    refute "rpg.narration.your_turn" in advertised
  end
end

defmodule BotArmyCompanion.NATS.ConsumerConnectRoleTest do
  @moduledoc """
  Which role the consumer serves with when it connects.

  The consumer starts in `:standby` so an unelected node never answers business
  traffic. But `LeaderElection` is started *before* the consumer and announces
  the applied role by cast — when a restarted bot still holds its KV lease the
  election applies `:primary` during boot, the cast lands on a name nobody has
  registered yet and is dropped, and the node then serves nothing at all: the
  reflect screens' `companion.reflections.list` had no responder for 23 minutes
  on 2026-10-20. The default must not outrank a reading of the applied role.
  """

  use ExUnit.Case, async: true

  @moduletag :nats

  alias BotArmyCompanion.NATS.Consumer

  test "a node the election already made primary serves, even though it started standby" do
    assert Consumer.connect_role(:standby, %{role: :primary, is_leader: true}) == :primary
  end

  test "a standby reading is honoured — two nodes must not both answer" do
    assert Consumer.connect_role(:standby, %{role: :standby, is_leader: false}) == :standby
  end

  test "an unknown reading keeps the cautious default" do
    assert Consumer.connect_role(:standby, %{role: :unknown, is_leader: false}) == :standby
  end

  test "a node that already decided primary stays primary" do
    assert Consumer.connect_role(:primary, %{role: :unknown, is_leader: false}) == :primary
  end
end
