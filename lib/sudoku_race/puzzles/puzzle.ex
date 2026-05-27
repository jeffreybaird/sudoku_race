defmodule SudokuRace.Puzzles.Puzzle do
  @moduledoc """
  Schema for a Sudoku puzzle from the seeded pool.

  Each puzzle stores an 81-character clue string (zeros represent blank cells),
  the 81-character solution string, a derived difficulty, and the count of
  non-zero cells (givens). Difficulty is derived from `givens_count` — see
  `SudokuRace.Puzzles.derive_difficulty/1` for the band thresholds.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SudokuRace.Puzzles

  @type t :: %__MODULE__{}

  schema "puzzles" do
    field :clues, :string
    field :solution, :string
    field :difficulty, Ecto.Enum, values: [:easy, :medium, :hard]
    field :givens_count, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a puzzle. Validates that clues and solution are exactly
  81 digits (0-9), that givens_count is consistent with the clues, and
  that difficulty is one of the valid enum values.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(puzzle, attrs) do
    puzzle
    |> cast(attrs, [:clues, :solution, :difficulty, :givens_count])
    |> validate_required([:clues, :solution, :difficulty, :givens_count])
    |> validate_81_digit_string(:clues)
    |> validate_81_digit_string(:solution)
    |> validate_number(:givens_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 81)
    |> validate_givens_count_consistent()
    |> unique_constraint(:clues)
  end

  defp validate_81_digit_string(changeset, field) do
    validate_format(changeset, field, ~r/\A[0-9]{81}\z/,
      message: "must be exactly 81 digits (0-9)"
    )
  end

  defp validate_givens_count_consistent(changeset) do
    clues = get_field(changeset, :clues)
    givens_count = get_field(changeset, :givens_count)

    if is_binary(clues) and not is_nil(givens_count) and
         String.length(clues) == 81 do
      actual = Puzzles.givens_count(clues)

      if actual == givens_count do
        changeset
      else
        add_error(
          changeset,
          :givens_count,
          "does not match the number of non-zero cells in clues"
        )
      end
    else
      changeset
    end
  end
end
