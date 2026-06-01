# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# In production, call the equivalent release task:
#
#     bin/sudoku_race eval "SudokuRace.Release.seed_puzzles()"

alias SudokuRace.Release

csv_path = Path.join(File.cwd!(), "data/puzzles.csv")

if File.exists?(csv_path) do
  {inserted, skipped} = Release.seed_puzzles_from_csv(csv_path)
  IO.puts("Puzzles seeded: #{inserted} inserted, #{skipped} skipped (already existed)")
else
  IO.puts("Warning: #{csv_path} not found — skipping puzzle seeding.")
  IO.puts("To seed puzzles, place puzzles.csv in the data/ directory and re-run.")
end
