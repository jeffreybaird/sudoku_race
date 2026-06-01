defmodule SudokuRace.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :string
    end

    # Optional username; NULLs don't collide, so multiple users may have none.
    create unique_index(:users, [:username])
  end
end
