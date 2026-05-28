defmodule SudokuRace.Social.Friendship do
  @moduledoc """
  Schema for a friendship between two users.

  ## Status state machine

      :pending  → accept_friend_request  → :accepted
      :pending  → decline_friend_request → (deleted)

  ## Direction-agnostic uniqueness

  The `friendships_pair_index` functional unique index on
  `(LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id))`
  ensures that only one row exists for any pair of users, regardless of who
  initiated the request. This prevents race conditions where A→B and B→A are
  both inserted concurrently.

  ## Self-friendship prevention

  Enforced at two layers:
  1. Changeset validation (`requester_id != addressee_id`)
  2. DB `CHECK (requester_id <> addressee_id)` constraint named `:no_self_friendship`
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SudokuRace.Accounts.User

  @type t :: %__MODULE__{}

  @valid_statuses [:pending, :accepted]

  schema "friendships" do
    belongs_to :requester, User
    belongs_to :addressee, User

    field :status, Ecto.Enum, values: @valid_statuses, default: :pending

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new friendship (friend request).

  `requester_id` and `addressee_id` must be set on the struct before calling
  this function — they are not cast for security.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(friendship, attrs) do
    friendship
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_no_self_friendship()
    |> unique_constraint([:requester_id, :addressee_id],
      name: :friendships_pair_index,
      message: "friendship already exists"
    )
    |> check_constraint(:requester_id,
      name: :no_self_friendship,
      message: "cannot befriend yourself"
    )
  end

  @doc """
  Changeset for updating friendship status (accept).
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(friendship, attrs) do
    friendship
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_no_self_friendship(changeset) do
    requester_id = get_field(changeset, :requester_id)
    addressee_id = get_field(changeset, :addressee_id)

    if not is_nil(requester_id) and not is_nil(addressee_id) and
         requester_id == addressee_id do
      add_error(changeset, :requester_id, "cannot befriend yourself")
    else
      changeset
    end
  end
end
