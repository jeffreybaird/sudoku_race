defmodule SudokuRace.Repo.Migrations.CreatePuzzles do
  use Ecto.Migration

  def change do
    create table(:puzzles) do
      add :clues, :string, null: false
      add :solution, :string, null: false
      add :difficulty, :string, null: false
      add :givens_count, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:puzzles, [:clues])
  end
end
