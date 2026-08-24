defmodule BotArmyCompanion.Handlers.ObservationsHandler do
  @moduledoc """
  Lets Abby browse Companion's PARA-stored reflections ("observations") and
  reply to them. Replies are appended to the same file via `para.fs.write`
  (mode "append") — the same mechanism `HeartbeatHandler` already uses to
  write the reflection in the first place.

  Reply sections are tagged `## Abby's reply — <timestamp>` so
  `BotArmyCompanion.ReflectionHistory` can tell them apart from Companion's
  own reflection sections when building context for the next reflection
  cycle on that angle.
  """

  require Logger

  alias BotArmyCompanion.ParaClient

  @observations_dir "areas/companion/observations"
  @filename_regex ~r/^\d{4}-\d{2}-\d{2}-angle-\d+\.md$/

  @doc """
  List recent observation files, newest first.

  Returns {:ok, [%{filename: ..., date: ..., angle: ...}]} or {:error, reason}.
  """
  def list_observations(limit \\ 20) do
    case ParaClient.list_directory(@observations_dir, false, 5_000) do
      {:ok, entries} ->
        observations =
          entries
          |> Enum.map(&parse_filename/1)
          |> Enum.filter(&(&1 != nil))
          |> Enum.sort_by(& &1.date, :desc)
          |> Enum.take(limit)

        {:ok, observations}

      error ->
        error
    end
  end

  @doc """
  Read one observation's full content by filename.

  Returns {:ok, content} or {:error, reason}. Rejects anything that isn't a
  bare `YYYY-MM-DD-angle-N.md` filename to keep the read inside the
  observations directory.
  """
  def read_observation(filename) do
    with :ok <- validate_filename(filename) do
      ParaClient.read_file("#{@observations_dir}/#{filename}", 5_000)
    end
  end

  @doc """
  Append Abby's reply to an observation file.

  Returns {:ok, "written"} or {:error, reason}.
  """
  def reply_to_observation(filename, reply_text)
      when is_binary(reply_text) and byte_size(reply_text) > 0 do
    with :ok <- validate_filename(filename) do
      content = format_reply(reply_text)

      payload = %{
        "schema_version" => "1.0",
        "relative_path" => "#{@observations_dir}/#{filename}",
        "content" => content,
        "mode" => "append"
      }

      call_nats_subject("para.fs.write", payload, 5_000)
      |> handle_write_response(filename)
    end
  end

  def reply_to_observation(_filename, _reply_text) do
    {:error, "Reply text must be a non-empty string"}
  end

  defp handle_write_response({:ok, %{"ok" => false} = response}, filename) do
    reason = Map.get(response, "error", "unknown error")
    Logger.error("para.fs.write rejected reply to #{filename}: #{reason}")
    {:error, "para.fs.write rejected: #{reason}"}
  end

  defp handle_write_response({:ok, _response}, filename) do
    Logger.info("Reply appended to #{filename}")
    {:ok, "written"}
  end

  defp handle_write_response(error, filename) do
    Logger.error("Failed to write reply to #{filename}: #{inspect(error)}")
    error
  end

  defp validate_filename(filename) when is_binary(filename) do
    if Regex.match?(@filename_regex, filename) do
      :ok
    else
      {:error, "Invalid observation filename: #{filename}"}
    end
  end

  defp validate_filename(_), do: {:error, "Invalid observation filename"}

  defp parse_filename(filename) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})-angle-(\d+)\.md$/, filename) do
      [_full, date, angle] ->
        %{filename: filename, date: date, angle: String.to_integer(angle)}

      _ ->
        nil
    end
  end

  defp format_reply(reply_text) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    ## Abby's reply — #{timestamp}

    #{reply_text}

    """
  end

  defp call_nats_subject(subject, payload, timeout_ms) do
    with {:ok, conn} <- get_nats_connection() do
      handle_nats_response(
        Gnat.request(conn, subject, Jason.encode!(payload), receive_timeout: timeout_ms),
        subject
      )
    end
  end

  defp handle_nats_response({:ok, msg}, _subject) do
    case Jason.decode(msg.body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp handle_nats_response({:error, :timeout}, subject) do
    {:error, "NATS request timeout on #{subject}"}
  end

  defp handle_nats_response({:error, :no_responders}, subject) do
    {:error, "No responders available for #{subject}"}
  end

  defp handle_nats_response({:error, reason}, subject) do
    {:error, "NATS error on #{subject}: #{inspect(reason)}"}
  end

  defp get_nats_connection do
    GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000)
  end
end
