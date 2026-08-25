defmodule BotArmyCompanion.ParaClient do
  @moduledoc """
  Client for reading/writing to PARA via NATS.

  Handles communication with para.fs.* endpoints.
  """

  require Logger

  @doc """
  Read a file from PARA.

  Returns {:ok, content} or {:error, reason}.
  """
  def read_file(relative_path, timeout_ms \\ 5_000) do
    Logger.debug("ParaClient.read_file: #{relative_path}")

    payload = %{
      "relative_path" => relative_path
    }

    case call_nats_subject("para.fs.read", payload, timeout_ms) do
      {:ok, %{"data" => data}} when is_map(data) ->
        case Map.get(data, "content") do
          content when is_binary(content) ->
            Logger.debug(
              "ParaClient.read_file: Successfully read #{String.length(content)} bytes"
            )

            {:ok, content}

          _ ->
            Logger.error("ParaClient.read_file: Missing 'content' in response")
            {:error, "Invalid response format"}
        end

      {:ok, response} ->
        Logger.error("ParaClient.read_file: Unexpected response: #{inspect(response)}")
        {:error, "Invalid response format"}

      error ->
        Logger.error("ParaClient.read_file: NATS error: #{inspect(error)}")
        error
    end
  end

  @doc """
  List directory contents in PARA.

  Returns {:ok, entries} or {:error, reason}.
  """
  def list_directory(relative_path, recursive \\ false, timeout_ms \\ 5_000) do
    Logger.debug("ParaClient.list_directory: #{relative_path} (recursive=#{recursive})")

    payload = %{
      "relative_path" => relative_path,
      "recursive" => recursive
    }

    case call_nats_subject("para.fs.list", payload, timeout_ms) do
      {:ok, %{"data" => %{"entries" => entries}}} when is_list(entries) ->
        Logger.debug("ParaClient.list_directory: Found #{length(entries)} entries")
        {:ok, entries}

      {:ok, response} ->
        Logger.error("ParaClient.list_directory: Unexpected response: #{inspect(response)}")
        {:error, "Invalid response format"}

      error ->
        Logger.error("ParaClient.list_directory: NATS error: #{inspect(error)}")
        error
    end
  end

  @doc """
  Write a file to PARA.

  Options:
  - :mode (default "write") - "write", "append", etc.
  - :timeout_ms (default 5000) - NATS request timeout

  Returns {:ok, %{bytes_written: N, ...}} or {:error, reason}.
  """
  def write_file(relative_path, content, opts \\ []) do
    Logger.debug("ParaClient.write_file: #{relative_path} (#{byte_size(content)} bytes)")

    mode = Keyword.get(opts, :mode, "write")
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    payload = %{
      "relative_path" => relative_path,
      "content" => content,
      "mode" => mode
    }

    case call_nats_subject("para.fs.write", payload, timeout_ms) do
      {:ok, %{"data" => data}} when is_map(data) ->
        case Map.get(data, "bytes_written") do
          bytes when is_integer(bytes) ->
            Logger.debug("ParaClient.write_file: Successfully wrote #{bytes} bytes")
            {:ok, data}

          _ ->
            Logger.error("ParaClient.write_file: Missing 'bytes_written' in response")
            {:error, "Invalid response format"}
        end

      {:ok, response} ->
        Logger.error("ParaClient.write_file: Unexpected response: #{inspect(response)}")
        {:error, "Invalid response format"}

      error ->
        Logger.error("ParaClient.write_file: NATS error: #{inspect(error)}")
        error
    end
  end

  @doc """
  Search PARA for files matching a query.

  Returns {:ok, results} or {:error, reason}.
  """
  def search(query, timeout_ms \\ 5_000) do
    Logger.debug("ParaClient.search: #{query}")

    payload = %{
      "query" => query
    }

    case call_nats_subject("para.fs.search", payload, timeout_ms) do
      {:ok, %{"data" => %{"results" => results}}} when is_list(results) ->
        Logger.debug("ParaClient.search: Found #{length(results)} results")
        {:ok, results}

      {:ok, response} ->
        Logger.error("ParaClient.search: Unexpected response: #{inspect(response)}")
        {:error, "Invalid response format"}

      error ->
        Logger.error("ParaClient.search: NATS error: #{inspect(error)}")
        error
    end
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
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end
end
