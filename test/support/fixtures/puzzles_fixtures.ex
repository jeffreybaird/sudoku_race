defmodule SudokuRace.PuzzlesFixtures do
  @moduledoc """
  Test helpers for creating entities via `SudokuRace.Puzzles` context.
  """

  alias SudokuRace.Puzzles

  @solution String.duplicate("9", 81)

  @doc """
  Returns a valid 81-digit clue string with the given number of non-zero cells.
  Fills from the left with `1`s and pads with `0`s.
  """
  def clue_with_givens(count) when count >= 0 and count <= 81 do
    String.duplicate("1", count) <> String.duplicate("0", 81 - count)
  end

  @doc """
  Inserts an easy puzzle (35 givens) into the database and returns it.
  Accepts optional attribute overrides.
  """
  def easy_puzzle_fixture(attrs \\ %{}) do
    givens = Map.get(attrs, :givens_count, 35)
    clue = Map.get(attrs, :clues, clue_with_givens(givens))

    row = %{
      clues: clue,
      solution: Map.get(attrs, :solution, @solution),
      givens_count: givens,
      difficulty: :easy
    }

    Puzzles.import_puzzles([row])
    [puzzle] = Puzzles.list_puzzles(difficulty: :easy)
    puzzle
  end

  @doc """
  Inserts a medium puzzle (34 givens) into the database and returns it.
  """
  def medium_puzzle_fixture(attrs \\ %{}) do
    givens = Map.get(attrs, :givens_count, 34)
    clue = Map.get(attrs, :clues, clue_with_givens(givens))

    row = %{
      clues: clue,
      solution: Map.get(attrs, :solution, @solution),
      givens_count: givens,
      difficulty: :medium
    }

    Puzzles.import_puzzles([row])
    [puzzle] = Puzzles.list_puzzles(difficulty: :medium)
    puzzle
  end

  @doc """
  Inserts a hard puzzle (33 givens) into the database and returns it.
  """
  def hard_puzzle_fixture(attrs \\ %{}) do
    givens = Map.get(attrs, :givens_count, 33)
    clue = Map.get(attrs, :clues, clue_with_givens(givens))

    row = %{
      clues: clue,
      solution: Map.get(attrs, :solution, @solution),
      givens_count: givens,
      difficulty: :hard
    }

    Puzzles.import_puzzles([row])
    [puzzle] = Puzzles.list_puzzles(difficulty: :hard)
    puzzle
  end

  @doc """
  Inserts one puzzle per difficulty band.
  Returns a list of three puzzles: [easy, medium, hard].
  """
  def all_difficulty_fixtures do
    easy_clue = clue_with_givens(35)
    medium_clue = clue_with_givens(34)
    hard_clue = clue_with_givens(33)

    Puzzles.import_puzzles([
      %{clues: easy_clue, solution: @solution, givens_count: 35, difficulty: :easy},
      %{clues: medium_clue, solution: @solution, givens_count: 34, difficulty: :medium},
      %{clues: hard_clue, solution: @solution, givens_count: 33, difficulty: :hard}
    ])

    Puzzles.list_puzzles()
  end
end
