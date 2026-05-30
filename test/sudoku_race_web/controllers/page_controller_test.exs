defmodule SudokuRaceWeb.PageControllerTest do
  use SudokuRaceWeb.ConnCase

  import SudokuRace.AccountsFixtures

  test "GET / shows the Sudoku Race landing for logged-out visitors", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Sudoku Race"
    assert response =~ ~p"/users/register"
    assert response =~ ~p"/users/log-in"
    # Phoenix marketing boilerplate is gone.
    refute response =~ "Peace of mind from prototype to production"
  end

  test "GET / redirects logged-in users to the puzzles app", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> get(~p"/")
    assert redirected_to(conn) == ~p"/puzzles"
  end
end
