defmodule SudokuRace.Repo.Migrations.CreateFriendships do
  use Ecto.Migration

  def up do
    create table(:friendships) do
      add :requester_id, references(:users, on_delete: :delete_all), null: false
      add :addressee_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    # Self-friend block at DB level
    create constraint(:friendships, :no_self_friendship, check: "requester_id <> addressee_id")

    # Hot-path indexes for friends?/2 queries (both directions)
    create index(:friendships, [:addressee_id, :status])
    create index(:friendships, [:requester_id, :status])

    # Race-safe uniqueness: a pair can only have one row regardless of direction.
    # Uses a functional index on (LEAST, GREATEST) so A→B and B→A share the same slot.
    execute(
      """
      CREATE UNIQUE INDEX friendships_pair_index
        ON friendships (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id));
      """,
      "DROP INDEX IF EXISTS friendships_pair_index;"
    )
  end

  def down do
    drop_if_exists index(:friendships, [:addressee_id, :status])
    drop_if_exists index(:friendships, [:requester_id, :status])
    execute("DROP INDEX IF EXISTS friendships_pair_index;", "")
    drop table(:friendships)
  end
end
