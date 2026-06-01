defmodule Mix.Tasks.SudokuRace.GrantAdmin do
  @shortdoc "Grants the admin role to a user by email"

  @moduledoc """
  Grants the admin role to the user with the given email.

      mix sudoku_race.grant_admin admin@example.com

  Dev/operator convenience. In production (releases have no Mix), use:

      bin/sudoku_race eval 'SudokuRace.Release.grant_admin("admin@example.com")'
  """

  use Mix.Task

  # Ensure the app + repo are started before touching the database.
  @requirements ["app.start"]

  @impl Mix.Task
  def run([email]) when is_binary(email) do
    case SudokuRace.Accounts.grant_admin_by_email(email) do
      {:ok, user} ->
        Mix.shell().info("Granted admin to #{user.email}")

      {:error, :not_found} ->
        Mix.raise("No user found with email #{email}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix sudoku_race.grant_admin <email>")
  end
end
