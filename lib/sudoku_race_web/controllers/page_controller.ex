defmodule SudokuRaceWeb.PageController do
  use SudokuRaceWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
