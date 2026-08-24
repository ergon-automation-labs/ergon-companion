defmodule BotArmyCompanion.Handlers.ObservationsHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyCompanion.Handlers.ObservationsHandler

  describe "read_observation/1 filename validation" do
    test "rejects filenames outside the observations directory" do
      assert {:error, _} = ObservationsHandler.read_observation("../../etc/passwd")
      assert {:error, _} = ObservationsHandler.read_observation("not-a-real-file.md")
      assert {:error, _} = ObservationsHandler.read_observation("2026-08-24-angle-3.md/../x")
    end
  end

  describe "reply_to_observation/2 validation" do
    test "rejects invalid filenames before attempting a NATS write" do
      assert {:error, _} =
               ObservationsHandler.reply_to_observation("../secrets.md", "hi")
    end

    test "rejects an empty reply" do
      assert {:error, _} =
               ObservationsHandler.reply_to_observation("2026-08-24-angle-3.md", "")
    end

    test "rejects a non-string reply" do
      assert {:error, _} =
               ObservationsHandler.reply_to_observation("2026-08-24-angle-3.md", nil)
    end
  end
end
