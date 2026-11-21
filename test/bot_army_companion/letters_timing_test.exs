defmodule BotArmyCompanion.LettersTimingTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyCompanion.Letters.Timing

  defp utc(s), do: DateTime.from_iso8601(s) |> elem(1)

  describe "to_local/1 (Denver)" do
    test "standard time is UTC-7, daylight time is UTC-6" do
      assert Timing.to_local(utc("2026-11-20T05:00:00Z")) == ~N[2026-11-19 22:00:00]
      assert Timing.to_local(utc("2026-07-01T18:00:00Z")) == ~N[2026-07-01 12:00:00]
    end

    test "the switch happens at 2:00 local on the US Sundays" do
      # 2026: DST starts Sunday 8 March, ends Sunday 1 November
      assert Timing.to_local(utc("2026-03-08T08:59:00Z")) == ~N[2026-03-08 01:59:00]
      assert Timing.to_local(utc("2026-03-08T09:00:00Z")) == ~N[2026-03-08 03:00:00]
      assert Timing.to_local(utc("2026-11-01T07:59:00Z")) == ~N[2026-11-01 01:59:00]
      assert Timing.to_local(utc("2026-11-01T08:00:00Z")) == ~N[2026-11-01 01:00:00]
    end
  end

  describe "deliver_at/1" do
    test "an evening letter is answered at 07:30 the next morning" do
      # 22:00 MST Thu 19 Nov -> 07:30 MST Fri 20 Nov = 14:30 UTC
      assert Timing.deliver_at(utc("2026-11-20T05:00:00Z")) == utc("2026-11-20T14:30:00Z")
    end

    test "an after-midnight letter is answered at 07:30 the same morning" do
      # 02:00 MST Fri 20 Nov -> 07:30 MST Fri 20 Nov
      assert Timing.deliver_at(utc("2026-11-20T09:00:00Z")) == utc("2026-11-20T14:30:00Z")
    end

    test "a daytime letter is answered three hours later" do
      assert Timing.deliver_at(utc("2026-11-20T17:00:00Z")) == utc("2026-11-20T20:00:00Z")
    end

    test "summer mornings use the daylight offset" do
      # 23:00 MDT Wed 1 Jul -> 07:30 MDT Thu 2 Jul = 13:30 UTC
      assert Timing.deliver_at(utc("2026-07-02T05:00:00Z")) == utc("2026-07-02T13:30:00Z")
    end

    test "18:00 is evening, 06:00 is day" do
      # 18:00 MST = 01:00 UTC next day
      assert Timing.deliver_at(utc("2026-11-21T01:00:00Z")) == utc("2026-11-21T14:30:00Z")
      # 06:00 MST = 13:00 UTC -> +3h
      assert Timing.deliver_at(utc("2026-11-20T13:00:00Z")) == utc("2026-11-20T16:00:00Z")
    end
  end

  describe "felt/2" do
    test "felt time, never a clock" do
      now = utc("2026-11-20T05:00:00Z")
      assert Timing.felt(Timing.deliver_at(now), now) == "tomorrow morning"

      day = utc("2026-11-20T17:00:00Z")
      assert Timing.felt(Timing.deliver_at(day), day) == "in about 3 hours"
      assert Timing.felt(DateTime.add(day, 30 * 60), day) == "within the hour"
      assert Timing.felt(day, day) == "any moment now"
    end

    test "an after-midnight letter is answered this morning, not 'in about 6 hours'" do
      # 02:00 MST Fri 20 Nov: due 07:30 the same morning.
      now = utc("2026-11-20T09:00:00Z")
      assert Timing.felt(Timing.deliver_at(now), now) == "this morning"
    end

    test "a daytime letter that lands before noon still says hours, not 'this morning'" do
      # 06:30 MST: day, so due 09:30 (three hours), which is not the overnight slot.
      now = utc("2026-11-20T13:30:00Z")
      assert Timing.felt(Timing.deliver_at(now), now) == "in about 3 hours"
    end

    test "an evening letter that is answered the next morning says tomorrow morning" do
      now = utc("2026-11-21T01:30:00Z")
      assert Timing.felt(Timing.deliver_at(now), now) == "tomorrow morning"
    end
  end
end
