defmodule BotArmyCompanion.ReflectionAnswer.Llm do
  @moduledoc """
  The seam between the companion and a language model.

  Deliberately narrow: the companion's answer side needs exactly one thing — ask
  a question, get words back and a note of which model wrote them — so that is
  the whole behaviour. Everything a *provider* needs (subjects, lanes, token
  budgets, polling) is passed in `opts` by the caller rather than read from
  config here, which is what lets a test answer in one line with **no broker and
  no model**:

      Mox.expect(ReflectionAnswerLlmMock, :answer, fn _system, _user, _opts ->
        {:ok, %{text: "that sounds heavy", model: "test"}}
      end)

  The failure vocabulary is small and closed on purpose. A caller that cannot
  tell "the bus dropped it" from "the model refused" will retry the wrong one:

  * `:unavailable` — the request never reached a model (no connection, no responder)
  * `:timeout`     — a model was asked, and did not finish inside the budget
  * `:empty_answer`— the job completed and carried no words
  * `:model_failed`— the job reported failure

  Implementations must never return a provider's own error message as the reason:
  that message can quote the request, and the request contains her words. A
  reason *code* is what crosses this seam.
  """

  @doc """
  Ask the model to answer, and wait for it within the caller's budget.

  `opts` are the provider's needs (`:subject`, `:status_subject`, `:model_type`,
  `:lane`, `:max_tokens`, `:budget_ms`, `:poll_ms`, …). Returns the words and the
  model that wrote them, or one of the codes above.
  """
  @callback answer(system :: String.t(), user :: String.t(), opts :: keyword()) ::
              {:ok, %{text: String.t(), model: String.t() | nil}} | {:error, atom()}
end

defmodule BotArmyCompanion.ReflectionAnswer.Llm.Nats do
  @moduledoc """
  The real model, over the fleet's bus.

  The uncensored lane is a *local* model and can take minutes, so this asks for a
  background job (`"async" => true`) and polls `llm.job.status` — the pattern the
  fleet documents for long generations. A blocking request would force this
  module to invent a deadline small enough to lose the answer.

  Two things here are load-bearing and easy to get wrong later:

  * **The model that answers is not the model that was configured.** The reply
    carries `model_used`, and it is stored, because a pillar that says `27B`
    while a `9B` answers is a fact worth being able to see.
  * **A pending job is not a failure.** A status request that times out is
    retried until the budget runs out; only repeated failures (or the budget)
    give up. The first timeout means "still working", which is the normal case
    for a minute-long generation.
  """

  @behaviour BotArmyCompanion.ReflectionAnswer.Llm

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  # How many status polls may fail in a row before we stop believing the job is
  # still coming. One timeout is "the model is thinking", three is "nobody is
  # answering".
  @max_status_errors 3

  @impl true
  def answer(system, user, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :budget_ms)

    payload = %{
      "system" => system,
      "messages" => [%{"role" => "user", "content" => user}],
      "model_type" => Keyword.fetch!(opts, :model_type),
      "lane" => Keyword.fetch!(opts, :lane),
      "max_tokens" => Keyword.fetch!(opts, :max_tokens),
      "async" => true
    }

    case submit(payload, opts) do
      {:ok, job_id} -> poll(job_id, deadline, opts, 0)
      {:error, code} -> {:error, code}
    end
  end

  defp submit(payload, opts) do
    case Publisher.request(Keyword.fetch!(opts, :subject), payload,
           timeout_ms: Keyword.fetch!(opts, :submit_timeout_ms)
         ) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) -> {:ok, job_id}
      {:ok, _other} -> {:error, :unavailable}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _other} -> {:error, :unavailable}
    end
  catch
    # A Gnat call to a connection that is not there *exits*. Rescuing alone would
    # miss it and take the caller down with it.
    _kind, _reason -> {:error, :unavailable}
  end

  defp poll(job_id, deadline, opts, errors) do
    cond do
      errors >= @max_status_errors ->
        {:error, :unavailable}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :timeout}

      true ->
        case status(job_id, opts) do
          {:done, result} -> take_result(result)
          :pending -> sleep_then_poll(job_id, deadline, opts, 0)
          :failed -> {:error, :model_failed}
          :missing -> {:error, :unavailable}
          :unreachable -> sleep_then_poll(job_id, deadline, opts, errors + 1)
        end
    end
  end

  defp sleep_then_poll(job_id, deadline, opts, errors) do
    Process.sleep(Keyword.fetch!(opts, :poll_ms))
    poll(job_id, deadline, opts, errors)
  end

  defp status(job_id, opts) do
    case Publisher.request(
           Keyword.fetch!(opts, :status_subject),
           %{"job_id" => job_id},
           timeout_ms: Keyword.fetch!(opts, :status_timeout_ms)
         ) do
      {:ok, %{"ok" => true, "status" => "completed", "result" => result}} -> {:done, result}
      {:ok, %{"ok" => true, "status" => "failed"}} -> :failed
      {:ok, %{"ok" => true, "status" => "pending"}} -> :pending
      {:ok, %{"ok" => false}} -> :missing
      {:ok, _other} -> :unreachable
      {:error, _other} -> :unreachable
    end
  catch
    _kind, _reason -> :unreachable
  end

  # A completed job whose result carries no words is not an answer. Storing an
  # empty string would make the row say "answered" about silence.
  defp take_result(result) when is_map(result) do
    text = Map.get(result, "content")

    if is_binary(text) and String.trim(text) != "" do
      {:ok, %{text: text, model: Map.get(result, "model_used")}}
    else
      {:error, :empty_answer}
    end
  end

  defp take_result(_other), do: {:error, :empty_answer}
end
