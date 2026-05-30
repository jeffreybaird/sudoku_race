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

    test "does not display the raw clue string; the play link reads 'Play'", %{conn: conn} do
      # Distinct clue so a leak would be unambiguous in the rendered HTML.
      clue = String.duplicate("1", 35) <> String.duplicate("0", 46)

      Puzzles.import_puzzles([
        %{clues: clue, solution: String.duplicate("9", 81), givens_count: 35, difficulty: :easy}
      ])

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      html = render(view)

      refute html =~ String.slice(clue, 0, 20)
      assert view |> element("[data-test='puzzle-play-link']") |> render() =~ "Play"
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
  # Status filter
  # ---------------------------------------------------------------------------
  describe "status filter" do
    setup :register_and_log_in_user

    import SudokuRace.SocialFixtures, only: [accepted_friendship_fixture: 2]

    alias SudokuRace.Attempts

    # Creates a unique easy puzzle with solution = all 9s (required for submit).
    # 35 "1" digits (the first 35 chars) guarantee difficulty: :easy.
    # The last 46 chars encode a unique integer so each puzzle has a distinct clue.
    defp unique_puzzle do
      i = System.unique_integer([:positive, :monotonic])
      # Encode i in the trailing 46 zeros as: pad i to 46 chars using "0" prefix
      # but we can't use "0" as a meaningful digit for givens_count. We only need
      # the clue to be unique — so encode i in the last 46 chars using only "0"
      # (zeros don't affect givens_count). Pad i's decimal with leading zeros.
      unique_suffix = Integer.to_string(i) |> String.pad_leading(46, "0") |> String.slice(-46, 46)
      clue = String.duplicate("1", 35) <> unique_suffix

      Puzzles.import_puzzles([
        %{
          clues: clue,
          solution: String.duplicate("9", 81),
          givens_count: Puzzles.givens_count(clue),
          difficulty: :easy
        }
      ])

      # Retrieve by matching the exact clue — safe within sandbox transaction.
      Puzzles.list_puzzles(difficulty: :easy, per_page: 100)
      |> Enum.find(fn p -> p.clues == clue end)
    end

    defp complete_puzzle(scope, puzzle) do
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _} = Attempts.submit_attempt(scope, attempt, String.duplicate("9", 81))
    end

    test "status filter buttons are present in the rendered HTML", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/puzzles")

      assert html =~ ~s(data-test="filter-status-all")
      assert html =~ ~s(data-test="filter-status-i-solved")
      assert html =~ ~s(data-test="filter-status-friend-solved")
      assert html =~ ~s(data-test="filter-status-unsolved")
    end

    test "clicking i-solved shows only puzzles I completed", %{conn: conn, scope: my_scope} do
      solved = unique_puzzle()
      _unsolved = unique_puzzle()
      complete_puzzle(my_scope, solved)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-i-solved']") |> render_click()
      html = render(view)

      assert html =~ ~s(id="puzzles-#{solved.id}")
    end

    test "i-solved excludes puzzles I have not completed", %{conn: conn, scope: my_scope} do
      solved = unique_puzzle()
      not_solved = unique_puzzle()
      complete_puzzle(my_scope, solved)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-i-solved']") |> render_click()
      html = render(view)

      refute html =~ ~s(id="puzzles-#{not_solved.id}")
    end

    test "friend-solved shows puzzle where friend completed but I did not", %{
      conn: conn,
      user: me
    } do
      friend = SudokuRace.AccountsFixtures.user_fixture()
      friend_scope = SudokuRace.AccountsFixtures.user_scope_fixture(friend)
      accepted_friendship_fixture(me, friend)

      puzzle = unique_puzzle()
      complete_puzzle(friend_scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-friend-solved']") |> render_click()
      html = render(view)

      assert html =~ ~s(id="puzzles-#{puzzle.id}")
    end

    # Product decision (user-directed): friend-solved shows any puzzle a friend
    # solved, including ones I also solved. The Hide-mine toggle filters those.
    test "friend-solved includes puzzle I also completed; hide-mine toggle removes it", %{
      conn: conn,
      user: me,
      scope: my_scope
    } do
      friend = SudokuRace.AccountsFixtures.user_fixture()
      friend_scope = SudokuRace.AccountsFixtures.user_scope_fixture(friend)
      accepted_friendship_fixture(me, friend)

      puzzle = unique_puzzle()
      complete_puzzle(my_scope, puzzle)
      complete_puzzle(friend_scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-friend-solved']") |> render_click()
      assert render(view) =~ ~s(id="puzzles-#{puzzle.id}")

      # Toggle "hide puzzles I've solved" → the mutually-solved puzzle drops off.
      view |> element("[data-test='toggle-hide-mine']") |> render_click()
      refute render(view) =~ ~s(id="puzzles-#{puzzle.id}")
    end

    test "friend-solved rows show the friend's email and solve time", %{conn: conn, user: me} do
      friend = SudokuRace.AccountsFixtures.user_fixture()
      friend_scope = SudokuRace.AccountsFixtures.user_scope_fixture(friend)
      accepted_friendship_fixture(me, friend)

      puzzle = unique_puzzle()
      complete_puzzle(friend_scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-friend-solved']") |> render_click()

      assert view |> element("[data-test='friend-solve-email']") |> render() =~ friend.email
      assert has_element?(view, "[data-test='friend-solve-time']")
    end

    test "hide-mine toggle is only shown on the friend-solved tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/puzzles")
      refute has_element?(view, "[data-test='toggle-hide-mine']")

      view |> element("[data-test='filter-status-friend-solved']") |> render_click()
      assert has_element?(view, "[data-test='toggle-hide-mine']")
    end

    test "unsolved shows puzzle with no completed attempts", %{conn: conn} do
      puzzle = unique_puzzle()

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-unsolved']") |> render_click()
      html = render(view)

      assert html =~ ~s(id="puzzles-#{puzzle.id}")
    end

    test "unsolved excludes puzzle I completed", %{conn: conn, scope: my_scope} do
      solved = unique_puzzle()
      complete_puzzle(my_scope, solved)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-unsolved']") |> render_click()
      html = render(view)

      refute html =~ ~s(id="puzzles-#{solved.id}")
    end

    test "status filter resets to page 1", %{conn: conn} do
      # Insert enough puzzles for multi-page (default per_page = 20, so insert 25)
      rows =
        for i <- 1..25 do
          clue = String.pad_leading(Integer.to_string(i), 81, "0")
          gc = Puzzles.givens_count(clue)

          %{
            clues: clue,
            solution: String.duplicate("9", 81),
            givens_count: gc,
            difficulty: Puzzles.derive_difficulty(gc)
          }
        end

      Puzzles.import_puzzles(rows)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='next-page']") |> render_click()
      # Now on page 2; applying a status filter should reset to page 1
      view |> element("[data-test='filter-status-unsolved']") |> render_click()

      refute has_element?(view, "[data-test='prev-page']")
    end

    test "status all button shows all puzzles (resets status filter)", %{
      conn: conn,
      scope: my_scope
    } do
      solved = unique_puzzle()
      not_solved = unique_puzzle()
      complete_puzzle(my_scope, solved)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-i-solved']") |> render_click()
      view |> element("[data-test='filter-status-all']") |> render_click()
      html = render(view)

      assert html =~ ~s(id="puzzles-#{solved.id}")
      assert html =~ ~s(id="puzzles-#{not_solved.id}")
    end

    test "status and difficulty filters can combine", %{conn: conn, scope: my_scope} do
      easy_puzzle = easy_puzzle_fixture()
      hard_puzzle = hard_puzzle_fixture()
      complete_puzzle(my_scope, easy_puzzle)
      complete_puzzle(my_scope, hard_puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles")
      view |> element("[data-test='filter-status-i-solved']") |> render_click()
      view |> element("[data-test='filter-easy']") |> render_click()
      html = render(view)

      assert html =~ ~s(id="puzzles-#{easy_puzzle.id}")
      refute html =~ ~s(id="puzzles-#{hard_puzzle.id}")
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
