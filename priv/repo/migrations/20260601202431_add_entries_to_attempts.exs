defmodule SudokuRace.Repo.Migrations.AddEntriesToAttempts do
  use Ecto.Migration

  def change do
    # Current board state (81-char string, "0" = blank), persisted as the user
    # plays so progress survives reconnects/deploys. Null for pre-existing rows.
    alter table(:attempts) do
      add :entries, :string
    end
  end
end
