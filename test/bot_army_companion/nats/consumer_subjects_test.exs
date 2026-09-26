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
end
