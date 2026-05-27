defmodule SudokuRace.AttemptsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `SudokuRace.Attempts` context.
  """

  alias SudokuRace.AccountsFixtures
  alias SudokuRace.Attempts
  alias SudokuRace.PuzzlesFixtures

  @doc """
  Creates a default puzzle suitable for attempt tests.
  Uses a solution of all nines so tests can submit `String.duplicate("9", 81)`.
  """
  def puzzle_fixture(attrs \\ %{}) do
    solution = Map.get(attrs, :solution, String.duplicate("9", 81))
    PuzzlesFixtures.easy_puzzle_fixture(%{solution: solution})
  end

  @doc """
  Creates an in-progress attempt for the given scope and puzzle.
  Both arguments default to newly-created fixtures if omitted.
  """
  def attempt_fixture(scope \\ nil, puzzle \\ nil, _attrs \\ %{}) do
    scope = scope || AccountsFixtures.user_scope_fixture()
    puzzle = puzzle || puzzle_fixture()

    {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
    attempt
  end
end
