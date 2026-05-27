defmodule SudokuRace.Puzzles do
  @moduledoc """
  Context for the Sudoku puzzle pool.

  ## Difficulty derivation policy

  Difficulty is derived from the number of non-zero ("given") cells in the
  81-character clue string. The public dataset (1 M puzzles) shows a tight
  givens distribution of 30–36:

      givens   ~%
        <=33   ~34%   → :hard
          34   ~45%   → :medium
        >=35   ~21%   → :easy

  Thresholds chosen to produce a non-degenerate three-band split across the
  real data. Higher givens = more information = easier puzzle.
  """

  import Ecto.Query

  alias SudokuRace.Puzzles.Puzzle
  alias SudokuRace.Repo

  @max_per_page 100
  @default_per_page 20

  # ---------------------------------------------------------------------------
  # Pure functions
  # ---------------------------------------------------------------------------

  @doc """
  Counts the number of non-zero characters in an 81-character clue string.
  Zero characters (`"0"`) represent blank cells; any other digit is a given.

  ## Examples

      iex> SudokuRace.Puzzles.givens_count(String.duplicate("0", 81))
      0

      iex> SudokuRace.Puzzles.givens_count(String.duplicate("5", 81))
      81

      iex> SudokuRace.Puzzles.givens_count("1" <> String.duplicate("0", 80))
      1

  """
  @spec givens_count(String.t()) :: non_neg_integer()
  def givens_count(clue) when is_binary(clue) do
    clue
    |> String.graphemes()
    |> Enum.count(&(&1 != "0"))
  end

  @doc """
  Maps a givens count to a difficulty atom using the dataset-derived thresholds:

  - `:easy`   — 35 or more givens  (~21% of the dataset)
  - `:medium` — exactly 34 givens  (~45% of the dataset)
  - `:hard`   — 33 or fewer givens (~34% of the dataset)

  ## Examples

      iex> SudokuRace.Puzzles.derive_difficulty(35)
      :easy

      iex> SudokuRace.Puzzles.derive_difficulty(36)
      :easy

      iex> SudokuRace.Puzzles.derive_difficulty(34)
      :medium

      iex> SudokuRace.Puzzles.derive_difficulty(33)
      :hard

      iex> SudokuRace.Puzzles.derive_difficulty(30)
      :hard

  """
  @spec derive_difficulty(non_neg_integer()) :: :easy | :medium | :hard
  def derive_difficulty(givens) when givens >= 35, do: :easy
  def derive_difficulty(34), do: :medium
  def derive_difficulty(_givens), do: :hard

  # ---------------------------------------------------------------------------
  # DB functions
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of puzzles, optionally filtered by difficulty.

  ## Options

  - `:page`       — 1-based page number (default: 1)
  - `:per_page`   — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  - `:difficulty` — one of `:easy`, `:medium`, `:hard`; omit for all difficulties

  """
  @spec list_puzzles(keyword()) :: [Puzzle.t()]
  def list_puzzles(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> min(@max_per_page)
    difficulty = Keyword.get(opts, :difficulty)
    offset = (page - 1) * per_page

    Puzzle
    |> apply_difficulty_filter(difficulty)
    |> order_by([p], asc: p.id)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts puzzles, optionally filtered by difficulty.

  ## Options

  - `:difficulty` — one of `:easy`, `:medium`, `:hard`; omit for all difficulties

  """
  @spec count_puzzles(keyword()) :: non_neg_integer()
  def count_puzzles(opts \\ []) do
    difficulty = Keyword.get(opts, :difficulty)

    Puzzle
    |> apply_difficulty_filter(difficulty)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Fetches a single puzzle by id.

  Returns `{:ok, puzzle}` on success or `{:error, :not_found}` if no puzzle
  with that id exists.
  """
  @spec get_puzzle(integer()) :: {:ok, Puzzle.t()} | {:error, :not_found}
  def get_puzzle(id) do
    case Repo.get(Puzzle, id) do
      nil -> {:error, :not_found}
      puzzle -> {:ok, puzzle}
    end
  end

  @doc """
  Bulk-inserts puzzles from a list of attribute maps.

  Uses `on_conflict: :nothing` with `conflict_target: :clues` so that
  re-running the seed never duplicates existing puzzles.

  Returns the count of rows actually inserted (skipped rows are not counted).
  Each map must include: `:clues`, `:solution`, `:givens_count`, `:difficulty`.
  """
  @spec import_puzzles([map()]) :: non_neg_integer()
  def import_puzzles(rows) when is_list(rows) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _} =
      Repo.insert_all(Puzzle, entries,
        on_conflict: :nothing,
        conflict_target: :clues
      )

    count
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_difficulty_filter(query, nil), do: query

  defp apply_difficulty_filter(query, difficulty) do
    where(query, [p], p.difficulty == ^difficulty)
  end
end
