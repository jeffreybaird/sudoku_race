defmodule SudokuRace.Repo.Migrations.AddNotesToAttempts do
  use Ecto.Migration

  def change do
    # Pencil-mark candidates per cell: %{"<position>" => [1, 4, 7], ...}.
    # Persisted alongside the board so notes survive reconnect/deploy.
    alter table(:attempts) do
      add :notes, :map, null: false, default: %{}
    end
  end
end
