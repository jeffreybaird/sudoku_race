defmodule SudokuRaceWeb.PageController do
  use SudokuRaceWeb, :controller

  def home(conn, _params) do
    # Logged-in users skip the marketing landing and go straight to the puzzles.
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/puzzles")
    else
      render(conn, :home)
    end
  end
end
