defmodule BotArmyCompanion.PrivateTest do
  @moduledoc """
  The rule this module exists to keep: a log line may say what a private value
  *is*, never what it says.

  These tests are written the way the leak happened — a real reflection map, a
  real model answer, a real exception — and they assert the absence of the words
  rather than the presence of a format. A test that only checked the format
  would pass just as happily on a describe/1 that appended the value after it.
  """

  use ExUnit.Case, async: true

  @moduletag :core

  alias BotArmyCompanion.Private

  @her_words "I keep circling the same drawer and I do not know why."

  describe "describe/1 — safe things stay readable" do
    test "a scalar is printed, because a number cannot carry a paragraph" do
      assert Private.describe(nil) == "nothing"
      assert Private.describe(3) == "3"
      assert Private.describe(true) == "true"
      assert Private.describe(:pending) == ":pending"
      assert Private.describe(1.5) == "1.5"
    end

    test "text is described by size, never by content" do
      assert Private.describe(@her_words) == "#{byte_size(@her_words)} bytes of text"
      refute Private.describe(@her_words) =~ "drawer"
    end

    test "a map is described by its keys" do
      assert Private.describe(%{"a" => "secret", "b" => 2}) == "a map (2 keys: a, b)"

      assert Private.describe(%{angle: 3, reflection: @her_words}) ==
               "a map (2 keys: angle, reflection)"
    end

    test "the keys of the assembled reflection context are visible, the values are not" do
      context = %{
        angle: 1,
        timestamp: "2026-09-26T05:00:00Z",
        active_tasks: "Active tasks: 25\n• brain",
        bot_health: "Bot health: unavailable",
        friction_summary: "Friction: unavailable",
        daily_log: "Recent progress: a private line",
        reflection: @her_words
      }

      described = Private.describe(context)

      assert described =~ "active_tasks"
      assert described =~ "daily_log"
      assert described =~ "7 keys"
      refute described =~ "brain"
      refute described =~ "private line"
      refute described =~ "drawer"
    end

    test "a struct is named, not printed — an exception's message is content too" do
      described = Private.describe(%RuntimeError{message: @her_words})

      assert described == "RuntimeError (1 key: message)"
      refute described =~ "drawer"
    end

    test "lists and tuples are counted" do
      assert Private.describe(["one", "two", "three"]) == "a list of 3"
      assert Private.describe({:error, "a private reason"}) == "a tuple of 2"
      assert Private.describe([]) == "a list of 0"
    end

    test "an empty map is described without inventing keys for it" do
      assert Private.describe(%{}) == "a map (no keys)"
    end

    test "a nested value is never reached" do
      described = Private.describe(%{inner: %{"text" => @her_words}})
      refute described =~ "drawer"
      assert described =~ "inner"
    end

    test "the same value always describes the same way" do
      map = %{"zeta" => 1, "alpha" => 2, "mid" => 3}
      assert Private.describe(map) == "a map (3 keys: alpha, mid, zeta)"
      assert Private.describe(map) == Private.describe(map)
    end

    test "something with no shape of its own is not guessed at" do
      assert Private.describe(self()) == "an opaque value"
      assert Private.describe(fn -> :ok end) == "a function"
    end
  end

  describe "the rule as the bot actually writes log lines" do
    test "a described payload has no words in it, at any log level" do
      payload = %{"text" => @her_words, "prompt" => "what is on your mind"}

      line = "Reflections.capture: payload (#{Private.describe(payload)})"

      assert line =~ "payload"
      refute line =~ "drawer"
      refute line =~ "what is on your mind"
    end
  end
end
