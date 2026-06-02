defmodule SudokuRace.Attempts.Attempt do
  @moduledoc """
  Schema for a user's attempt at solving a puzzle.

  Timing is server-authoritative. The `elapsed_seconds` column is written
  only on completion via `submit_attempt/3`. Do not update it on pause/resume.

  ## Status state machine

      :in_progress → pause_attempt → :paused
      :paused      → resume_attempt → :in_progress
      :in_progress → submit_attempt (correct) → :completed
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SudokuRace.Accounts.User
  alias SudokuRace.Puzzles.Puzzle

  @type t :: %__MODULE__{}

  @valid_statuses [:in_progress, :paused, :completed]

  schema "attempts" do
    belongs_to :user, User
    belongs_to :puzzle, Puzzle

    field :status, Ecto.Enum, values: @valid_statuses, default: :in_progress
    field :started_at, :utc_datetime_usec
    field :accumulated_seconds, :integer, default: 0
    field :segment_started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :elapsed_seconds, :integer
    # Current board (81-char string, "0" = blank); persisted as the user plays
    # so progress survives reconnects/deploys.
    field :entries, :string
    # Pencil-mark candidates per cell: %{"<position>" => [1, 4, 7], ...}.
    field :notes, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new attempt. User and puzzle FKs must be set on
  the struct before calling this function — they are not cast for security.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:status, :started_at, :segment_started_at, :accumulated_seconds])
    |> validate_required([:status, :started_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:user_id, :puzzle_id], name: :attempts_user_id_puzzle_id_index)
  end

  @doc """
  Changeset for updating attempt state (pause, resume, complete).
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :status,
      :accumulated_seconds,
      :segment_started_at,
      :completed_at,
      :elapsed_seconds,
      :entries,
      :notes
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
