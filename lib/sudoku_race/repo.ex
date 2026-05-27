defmodule SudokuRace.Repo do
  use Ecto.Repo,
    otp_app: :sudoku_race,
    adapter: Ecto.Adapters.Postgres
end
