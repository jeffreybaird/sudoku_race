defmodule SudokuRace.SocialFixtures do
  @moduledoc """
  Test helpers for creating entities via the `SudokuRace.Social` context.
  """

  alias SudokuRace.Accounts.User
  alias SudokuRace.Repo
  alias SudokuRace.Social.Friendship

  @doc """
  Inserts a pending friendship directly (bypasses context pre-checks).
  Useful for setting up test state.
  """
  def pending_friendship_fixture(%User{} = requester, %User{} = addressee) do
    %Friendship{requester_id: requester.id, addressee_id: addressee.id}
    |> Friendship.create_changeset(%{status: :pending})
    |> Repo.insert!()
  end

  @doc """
  Inserts an accepted friendship directly (bypasses context pre-checks).
  Useful for setting up test state.
  """
  def accepted_friendship_fixture(%User{} = requester, %User{} = addressee) do
    %Friendship{requester_id: requester.id, addressee_id: addressee.id}
    |> Friendship.create_changeset(%{status: :pending})
    |> Repo.insert!()
    |> Friendship.update_changeset(%{status: :accepted})
    |> Repo.update!()
  end
end
