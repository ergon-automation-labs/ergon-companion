defmodule BotArmyCompanion.CompanionThought do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "companion_thoughts" do
    field(:angle, :integer)
    field(:query, :string)
    field(:active, :boolean, default: true)
    field(:priority, :integer, default: 0)
    field(:tags, {:array, :string}, default: [])

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(companion_thought, attrs) do
    companion_thought
    |> cast(attrs, [:angle, :query, :active, :priority, :tags])
    |> validate_required([:angle, :query])
    |> validate_inclusion(:angle, 0..3)
    |> unique_constraint(:angle)
  end
end
