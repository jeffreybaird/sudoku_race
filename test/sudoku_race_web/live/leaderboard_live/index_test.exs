defmodule SudokuRaceWeb.LeaderboardLive.IndexTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.AccountsFixtures
  import SudokuRace.PuzzlesFixtures
  import SudokuRace.SocialFixtures

  alias SudokuRace.Attempts
  alias SudokuRace.Puzzles

  @solution String.duplicate("9", 81)

  # Helper: complete a puzzle as the given user, returning the completed attempt.
  defp complete(scope, puzzle) do
    {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
    {:ok, completed} = Attempts.submit_attempt(scope, attempt, @solution)
    completed
  end

  # Inserts `n` easy puzzles with distinct clues and returns them. The shared
  # difficulty fixtures only allow one puzzle per difficulty, so bulk seeding
  # goes through the context directly.
  defp seed_easy_puzzles(n) do
    rows =
      for g <- 20..(19 + n) do
        %{
          clues: clue_with_givens(g),
          solution: @solution,
          givens_count: g,
          difficulty: :easy
        }
      end

    Puzzles.import_puzzles(rows)
    Puzzles.list_puzzles(difficulty: :easy, per_page: 100)
  end

  # ---------------------------------------------------------------------------
  # Authentication gate
  # ---------------------------------------------------------------------------
  describe "route requires authentication" do
    test "redirects unauthenticated users to log-in", %{conn: conn} do
      {:error, redirect} = live(conn, ~p"/leaderboard")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------
  describe "index renders" do
    setup :register_and_log_in_user

    test "prompts to add a friend when the user has none", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/leaderboard")
      assert has_element?(view, "[data-test='no-friends']")
    end

    test "shows empty state when friends exist but none have solved a puzzle",
         %{conn: conn, user: me} do
      _friend = friend_for(me)
      {:ok, view, _html} = live(conn, ~p"/leaderboard")
      assert has_element?(view, "[data-test='no-entries']")
    end

    test "lists a friend's solved puzzle with their time", %{conn: conn, user: me} do
      {friend, friend_scope} = friend_for(me)
      puzzle = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})
      complete(friend_scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      assert has_element?(view, "[data-test='leaderboard-row']")
      assert view |> element("[data-test='leaderboard-user']") |> render() =~ friend.email
      assert has_element?(view, "[data-test='leaderboard-puzzle-link']")
      assert has_element?(view, "[data-test='leaderboard-time']")
    end

    test "does not show a stranger's solves", %{conn: conn, user: me} do
      _friend = friend_for(me)
      stranger_scope = user_scope_fixture(user_fixture())
      puzzle = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})
      complete(stranger_scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/leaderboard")
      assert has_element?(view, "[data-test='no-entries']")
      refute has_element?(view, "[data-test='leaderboard-row']")
    end
  end

  # ---------------------------------------------------------------------------
  # Pagination
  # ---------------------------------------------------------------------------
  describe "pagination" do
    setup :register_and_log_in_user

    test "next/prev page through a friend's solves", %{conn: conn, user: me} do
      {_friend, friend_scope} = friend_for(me)

      for puzzle <- seed_easy_puzzles(21) do
        complete(friend_scope, puzzle)
      end

      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      # Page 1 is full (20 rows) → Next is offered, Prev is not.
      assert has_element?(view, "[data-test='next-page']")
      refute has_element?(view, "[data-test='prev-page']")

      view |> element("[data-test='next-page']") |> render_click()

      # Page 2 has the 21st row → Prev is offered, Next is gone.
      assert has_element?(view, "[data-test='prev-page']")
      refute has_element?(view, "[data-test='next-page']")
    end

    test "exactly one full page shows no phantom Next button", %{conn: conn, user: me} do
      {_friend, friend_scope} = friend_for(me)

      for puzzle <- seed_easy_puzzles(20) do
        complete(friend_scope, puzzle)
      end

      {:ok, view, _html} = live(conn, ~p"/leaderboard")

      # 20 rows fill the page exactly — there is no next page, so no Next button
      # (which would otherwise lead to a misleading empty page).
      refute has_element?(view, "[data-test='next-page']")
      assert has_element?(view, "[data-test='leaderboard-row']")
    end
  end

  # Creates an accepted friend of `me`, returns {friend_user, friend_scope}.
  defp friend_for(me) do
    friend = user_fixture()
    accepted_friendship_fixture(me, friend)
    {friend, user_scope_fixture(friend)}
  end
end
