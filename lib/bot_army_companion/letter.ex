defmodule BotArmyCompanion.Letter do
  @moduledoc """
  One letter in the pen-pal thread between Abby and Eir.

  `body` is a sealed envelope (`BotArmyCompanion.Sealed`), never the text: the table holds
  ciphertext, bound to the letter's id so a body cannot be moved onto another row. See the
  migration for what `kind`, `status`, `deliver_at` and `dedupe_key` mean.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @authors ~w(abby eir)
  @kinds ~w(normal safety)
  @statuses ~w(none waiting writing answered failed)

  schema "letters" do
    field(:author, :string)
    field(:body, :map)
    field(:reply_to_id, :binary_id)
    field(:kind, :string, default: "normal")
    field(:status, :string, default: "none")
    field(:dedupe_key, :string)
    field(:deliver_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def authors, do: @authors
  def statuses, do: @statuses

  def changeset(letter, attrs) do
    letter
    |> cast(attrs, [:id, :author, :body, :reply_to_id, :kind, :status, :dedupe_key, :deliver_at])
    |> validate_required([:id, :author, :body, :kind, :status])
    |> validate_inclusion(:author, @authors)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:dedupe_key)
  end
end
