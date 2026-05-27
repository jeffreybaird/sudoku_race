defmodule SudokuRace.Repo.Migrations.CreateAttempts do
  use Ecto.Migration

  def change do
    create table(:attempts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :puzzle_id, references(:puzzles, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "in_progress"
      add :started_at, :utc_datetime_usec, null: false
      add :accumulated_seconds, :integer, null: false, default: 0
      add :segment_started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :elapsed_seconds, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:attempts, [:user_id, :puzzle_id])
  end
end
