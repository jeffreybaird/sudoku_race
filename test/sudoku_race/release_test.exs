defmodule SudokuRace.ReleaseTest do
  use SudokuRace.DataCase, async: true

  alias SudokuRace.{Puzzles, Release}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a valid 81-digit clue string (all zeros)
  defp valid_clue, do: String.duplicate("0", 81)

  # Build a valid 81-digit solution string (all nines)
  defp valid_solution, do: String.duplicate("9", 81)

  defp write_csv(lines) do
    path = Path.join(System.tmp_dir!(), "release_test_#{:erlang.unique_integer([:positive])}.csv")
    content = Enum.join(["quiz,solution" | lines], "\n") <> "\n"
    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # seed_puzzles_from_csv/1 — input validation
  # ---------------------------------------------------------------------------
  describe "seed_puzzles_from_csv/1 input validation" do
    test "accepts a valid 81-digit clue and solution row" do
      path = write_csv(["#{valid_clue()},#{valid_solution()}"])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 1
      assert Puzzles.count_puzzles() == 1
    end

    test "rejects a row where the quiz contains non-digit characters" do
      bad_quiz = String.duplicate("x", 81)
      path = write_csv(["#{bad_quiz},#{valid_solution()}"])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 0
      assert Puzzles.count_puzzles() == 0
    end

    test "rejects a row where the solution contains non-digit characters" do
      bad_solution = String.duplicate("a", 81)
      path = write_csv(["#{valid_clue()},#{bad_solution}"])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 0
      assert Puzzles.count_puzzles() == 0
    end

    test "rejects a row where the quiz is wrong length (not 81 chars)" do
      short_quiz = String.duplicate("0", 80)
      path = write_csv(["#{short_quiz},#{valid_solution()}"])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 0
      assert Puzzles.count_puzzles() == 0
    end

    test "rejects a row where the solution is wrong length (not 81 chars)" do
      short_solution = String.duplicate("9", 82)
      path = write_csv(["#{valid_clue()},#{short_solution}"])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 0
      assert Puzzles.count_puzzles() == 0
    end

    test "inserts only valid rows when mixed with invalid ones" do
      bad_quiz = String.duplicate("x", 81)
      valid_row = "#{valid_clue()},#{valid_solution()}"
      invalid_row = "#{bad_quiz},#{valid_solution()}"
      path = write_csv([valid_row, invalid_row])
      {inserted, _} = Release.seed_puzzles_from_csv(path)
      assert inserted == 1
      assert Puzzles.count_puzzles() == 1
    end

    test "skips malformed rows without crashing (does not raise)" do
      path = write_csv(["not,a,valid,csv,line", "#{valid_clue()},#{valid_solution()}"])

      assert {1, _} = Release.seed_puzzles_from_csv(path)
    end
  end
end
