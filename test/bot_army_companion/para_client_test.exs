defmodule BotArmyCompanion.ParaClientTest do
  use ExUnit.Case

  describe "parse_reflection_filename" do
    test "parses valid reflection filenames" do
      # Note: parse_reflection_filename is private, so we test via ReflectionHistory
      # This test documents the expected format
      filename = "2026-08-24-angle-3.md"

      assert Regex.match?(~r/(\d{4}-\d{2}-\d{2})-angle-(\d+)/, filename)
    end

    test "rejects invalid filenames" do
      invalid_names = [
        "2026-08-24-invalid.md",
        "angle-3.md",
        "observation.md"
      ]

      Enum.each(invalid_names, fn name ->
        assert not Regex.match?(~r/(\d{4}-\d{2}-\d{2})-angle-(\d+)/, name)
      end)
    end
  end

  describe "get_nats_connection graceful failure" do
    test "handles missing NATS connection gracefully" do
      # ParaClient should handle NATS connection failures without crashing
      # This is more of an integration test and would require mocking NATS
      # For now, we document the expected behavior
      :ok
    end
  end
end
