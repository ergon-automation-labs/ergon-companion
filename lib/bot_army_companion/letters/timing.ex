defmodule BotArmyCompanion.Letters.Timing do
  @moduledoc """
  When Eir's reply arrives — a pen pal's pace, not a chat's.

  A letter written in the evening or overnight (18:00 to 06:00 in Denver) is answered the next
  morning at 07:30. One written in the day is answered a few hours later (`@daytime_hours`).
  The wording on the card is felt time ("tomorrow morning", "in about 3 hours"), never a clock.

  Denver time is computed from UTC with the US daylight-saving rule (second Sunday of March to
  the first Sunday of November, 2:00 local), so no timezone database is needed. Pure functions:
  every one takes `now`.
  """

  @evening_starts 18
  @morning_ends 6
  @morning_delivery ~T[07:30:00]
  @daytime_hours 3

  @doc "When a reply to a letter written at `now` (UTC) arrives, in UTC."
  @spec deliver_at(DateTime.t()) :: DateTime.t()
  def deliver_at(%DateTime{} = now) do
    local = to_local(now)

    cond do
      local.hour >= @evening_starts ->
        local |> NaiveDateTime.to_date() |> Date.add(1) |> morning_utc()

      local.hour < @morning_ends ->
        local |> NaiveDateTime.to_date() |> morning_utc()

      true ->
        DateTime.add(now, @daytime_hours * 3600, :second)
    end
  end

  @doc "How the card says when the reply comes: felt time, never a timestamp."
  @spec felt(DateTime.t(), DateTime.t()) :: String.t()
  def felt(%DateTime{} = deliver_at, %DateTime{} = now) do
    minutes = div(DateTime.diff(deliver_at, now, :second), 60)
    same_day = NaiveDateTime.to_date(to_local(deliver_at)) == NaiveDateTime.to_date(to_local(now))

    cond do
      minutes <= 0 -> "any moment now"
      minutes < 60 -> "within the hour"
      # The overnight slot, whichever side of midnight the letter was written: a 2 a.m. letter
      # is answered "this morning" (same date), an 11 p.m. one "tomorrow morning".
      morning_slot?(deliver_at) and same_day -> "this morning"
      morning_slot?(deliver_at) -> "tomorrow morning"
      minutes < 90 -> "in about an hour"
      true -> "in about #{round(minutes / 60)} hours"
    end
  end

  # 07:30 Denver is only ever produced by the overnight rule (a daytime reply is `now` plus
  # three hours, which never lands on exactly 07:30 from a letter written after 06:00).
  defp morning_slot?(deliver_at) do
    local = to_local(deliver_at)
    {local.hour, local.minute} == {@morning_delivery.hour, @morning_delivery.minute}
  end

  @doc "Denver wall-clock time for a UTC instant."
  @spec to_local(DateTime.t()) :: NaiveDateTime.t()
  def to_local(%DateTime{} = utc) do
    naive = DateTime.to_naive(utc)
    NaiveDateTime.add(naive, offset_hours(naive) * 3600, :second)
  end

  defp morning_utc(date) do
    local = NaiveDateTime.new!(date, @morning_delivery)
    # Standard-time offset first; if that instant is in DST, use the DST offset.
    guess = NaiveDateTime.add(local, 7 * 3600, :second)
    utc = NaiveDateTime.add(local, -offset_hours(guess) * 3600, :second)
    DateTime.from_naive!(utc, "Etc/UTC")
  end

  # -6 during US daylight time, -7 otherwise. `naive_utc` is a UTC wall time.
  defp offset_hours(naive_utc) do
    year = naive_utc.year
    # DST starts 2:00 MST (09:00 UTC) on the second Sunday of March,
    # and ends 2:00 MDT (08:00 UTC) on the first Sunday of November.
    starts = NaiveDateTime.new!(nth_sunday(year, 3, 2), ~T[09:00:00])
    ends = NaiveDateTime.new!(nth_sunday(year, 11, 1), ~T[08:00:00])

    if NaiveDateTime.compare(naive_utc, starts) != :lt and
         NaiveDateTime.compare(naive_utc, ends) == :lt,
       do: -6,
       else: -7
  end

  defp nth_sunday(year, month, n) do
    first = Date.new!(year, month, 1)
    # Date.day_of_week: Monday 1 .. Sunday 7
    offset = rem(7 - Date.day_of_week(first), 7)
    Date.add(first, offset + 7 * (n - 1))
  end
end
