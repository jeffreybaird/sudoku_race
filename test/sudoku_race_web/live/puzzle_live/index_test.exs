defmodule SudokuRaceWeb.PuzzleLive.IndexTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.PuzzlesFixtures

  alias SudokuRace.Puzzles

  # ---------------------------------------------------------------------------
  # Authentication gate
  # ---------------------------------------------------------------------------
  describe "route requires authentication" do
    test "redirects unauthenticated users to log-in", %{conn: conn} do
      {:error, redirect} = live(conn, ~p"/puzzles")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering the puzzle list
  # ---------------------------------------------------------------------------
  describe "index renders" do
    setup :register_and_log_in_user

    test "shows the page with the puzzle list container", %{conn: conn} do
      _puzzles = all_difficulty_fixtures()
      {:ok, _view, html} = live(conn, ~p"/puzzles")
      assert html =~ "Puzzles"
    end

    test "renders a row for each puzzle in the page", %{conn: conn} do
      _puzzles = all_difficulty_fixtures()
      {:ok, view, _html} = live(conn, ~p"/puzzles")

      assert has_element?(view, "[data-test='puzzle-row']")
      # 3 puzzles inserted via all_difficulty_fixtures
      assert view |> element("[data-test='puzzle-list']") |> render() =~
               "data-test=\"puzzle-row\""
    end

    test "displays difficulty labels for each puzzle", %{conn: conn} do
      _puzzles = all_difficulty_fixtures()
      {:ok, _view, html} = live(conn, ~p"/puzzles")

      assert html =~ "easy"
      assert html =~ "medium"
      assert html =~ "hard"
    end
  end

  # ---------------------------------------------------------------------------
  # Difficulty filter
  # ---------------------------------------------------------------------------
  describe "difficulty filter" do
    setup :register_and_log_in_user

    setup do
      _puzzles = all_difficulty_fixtures()
      :ok
    end

    test "shows all puzzles by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      rows = view |> render() |> count_data_test_occurrences("puzzle-row")
      assert rows == 3
    end

    test "filter by easy shows only easy puzzles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-easy']") |> render_click()
      html = render(view)
      assert html =~ "easy"
      refute html =~ ~s(data-test="difficulty-medium")
      refute html =~ ~s(data-test="difficulty-hard")
    end

    test "filter by medium shows only medium puzzles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-medium']") |> render_click()
      html = render(view)
      assert html =~ "medium"
      refute html =~ ~s(data-test="difficulty-easy")
      refute html =~ ~s(data-test="difficulty-hard")
    end

    test "filter by hard shows only hard puzzles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-hard']") |> render_click()
      html = render(view)
      assert html =~ "hard"
      refute html =~ ~s(data-test="difficulty-easy")
      refute html =~ ~s(data-test="difficulty-medium")
    end

    test "filter all resets to all difficulties", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-easy']") |> render_click()
      view |> element("[data-test='filter-all']") |> render_click()
      rows = view |> render() |> count_data_test_occurrences("puzzle-row")
      assert rows == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination
  # ---------------------------------------------------------------------------
  describe "pagination" do
    setup :register_and_log_in_user

    test "shows next page button when there are more puzzles", %{conn: conn} do
      # Insert enough puzzles to require pagination (default per_page is 20)
      rows =
        for i <- 1..25 do
          givens = 33

          clue =
            String.duplicate("#{rem(i, 9) + 1}", givens) <> String.duplicate("0", 81 - givens)

          # Make each clue unique by appending a unique suffix
          unique_clue =
            String.slice(clue, 0, 70) <>
              String.pad_leading(Integer.to_string(i), 11, "0")

          %{
            clues: unique_clue,
            solution: String.duplicate("9", 81),
            givens_count: givens,
            difficulty: :hard
          }
        end

      Puzzles.import_puzzles(rows)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      assert has_element?(view, "[data-test='next-page']")
    end

    test "navigating to the next page loads more puzzles", %{conn: conn} do
      rows =
        for i <- 1..25 do
          givens = 33

          unique_clue =
            String.slice(String.duplicate("1", 81), 0, 70) <>
              String.pad_leading(Integer.to_string(i), 11, "0")

          %{
            clues: unique_clue,
            solution: String.duplicate("9", 81),
            givens_count: givens,
            difficulty: :hard
          }
        end

      Puzzles.import_puzzles(rows)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='next-page']") |> render_click()

      # After clicking next, we should be on page 2
      assert has_element?(view, "[data-test='prev-page']")
    end

    test "prev page is not shown on page 1", %{conn: conn} do
      _puzzles = all_difficulty_fixtures()
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      refute has_element?(view, "[data-test='prev-page']")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp count_data_test_occurrences(html, test_attr) do
    html
    |> String.split(~s(data-test="#{test_attr}"))
    |> length()
    |> Kernel.-(1)
  end
end
