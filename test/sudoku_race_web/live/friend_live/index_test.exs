defmodule SudokuRaceWeb.FriendLive.IndexTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.AccountsFixtures
  import SudokuRace.SocialFixtures

  alias SudokuRace.Accounts.Scope
  alias SudokuRace.Social

  # ---------------------------------------------------------------------------
  # Authentication gate
  # ---------------------------------------------------------------------------
  describe "route requires authentication" do
    test "redirects unauthenticated users to log-in", %{conn: conn} do
      {:error, redirect} = live(conn, ~p"/friends")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------
  describe "index renders" do
    setup :register_and_log_in_user

    test "shows the page with the add-friend form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/friends")
      assert html =~ "Friends"
      assert has_element?(view, "[data-test='add-friend-form']")
      assert has_element?(view, "[data-test='friend-email-input']")
    end

    test "shows empty states when there are no friends or requests", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/friends")
      assert has_element?(view, "[data-test='no-friends']")
      assert has_element?(view, "[data-test='no-pending-requests']")
    end

    test "lists incoming pending requests with the requester's email", %{conn: conn, user: alice} do
      bob = user_fixture()
      _req = pending_friendship_fixture(bob, alice)

      {:ok, view, _html} = live(conn, ~p"/friends")

      assert has_element?(view, "[data-test='pending-request-row']")
      assert view |> element("[data-test='requester-email']") |> render() =~ bob.email
    end

    test "lists current friends", %{conn: conn, user: alice} do
      bob = user_fixture()
      _friendship = accepted_friendship_fixture(bob, alice)

      {:ok, view, _html} = live(conn, ~p"/friends")

      assert has_element?(view, "[data-test='friend-row']")
      assert view |> element("[data-test='friend-email']") |> render() =~ bob.email
    end
  end

  # ---------------------------------------------------------------------------
  # Sending a friend request
  # ---------------------------------------------------------------------------
  describe "send_request" do
    setup :register_and_log_in_user

    test "sends a request to an existing user and shows confirmation", %{conn: conn} do
      bob = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/friends")

      html =
        view
        |> form("[data-test='add-friend-form']", %{"email" => bob.email})
        |> render_submit()

      assert html =~ "Friend request sent."
    end

    test "shows error when no user has that email", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/friends")

      view
      |> form("[data-test='add-friend-form']", %{"email" => "nobody@example.com"})
      |> render_submit()

      assert view |> element("[data-test='friend-email-error']") |> render() =~
               "No user found with that email."
    end

    test "shows error when sending a request to yourself", %{conn: conn, user: alice} do
      {:ok, view, _html} = live(conn, ~p"/friends")

      view
      |> form("[data-test='add-friend-form']", %{"email" => alice.email})
      |> render_submit()

      assert view |> element("[data-test='friend-email-error']") |> render() =~
               "You cannot befriend yourself."
    end

    test "shows error when already friends", %{conn: conn, user: alice} do
      bob = user_fixture()
      _friendship = accepted_friendship_fixture(alice, bob)
      {:ok, view, _html} = live(conn, ~p"/friends")

      view
      |> form("[data-test='add-friend-form']", %{"email" => bob.email})
      |> render_submit()

      assert view |> element("[data-test='friend-email-error']") |> render() =~
               "You are already friends."
    end

    test "shows error when a request was already sent", %{conn: conn, user: alice} do
      bob = user_fixture()
      _pending = pending_friendship_fixture(alice, bob)
      {:ok, view, _html} = live(conn, ~p"/friends")

      view
      |> form("[data-test='add-friend-form']", %{"email" => bob.email})
      |> render_submit()

      assert view |> element("[data-test='friend-email-error']") |> render() =~
               "You already sent them a request."
    end

    test "tells the user to accept below when the other party already requested them",
         %{conn: conn, user: alice} do
      bob = user_fixture()
      _incoming = pending_friendship_fixture(bob, alice)
      {:ok, view, _html} = live(conn, ~p"/friends")

      html =
        view
        |> form("[data-test='add-friend-form']", %{"email" => bob.email})
        |> render_submit()

      assert html =~ "They already sent you a request"
      # The incoming request is now visible for acceptance.
      assert has_element?(view, "[data-test='pending-request-row']")
    end
  end

  # ---------------------------------------------------------------------------
  # Accepting / declining requests
  # ---------------------------------------------------------------------------
  describe "accept" do
    setup :register_and_log_in_user

    test "accepts a pending request and the requester becomes a friend",
         %{conn: conn, user: alice} do
      bob = user_fixture()
      request = pending_friendship_fixture(bob, alice)
      {:ok, view, _html} = live(conn, ~p"/friends")

      html =
        view
        |> element("[data-test='accept-request-button'][phx-value-id='#{request.id}']")
        |> render_click()

      assert html =~ "Friend request accepted."
      assert has_element?(view, "[data-test='friend-row']")
      assert has_element?(view, "[data-test='no-pending-requests']")
    end

    test "shows an error when the request no longer exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/friends")

      html = render_click(view, "accept", %{"id" => "999999"})

      assert html =~ "That request no longer exists."
    end

    test "shows an error when acting on a request not addressed to the user",
         %{conn: conn} do
      bob = user_fixture()
      carol = user_fixture()
      # Request between two other users — current user is not the addressee.
      other_request = pending_friendship_fixture(bob, carol)
      {:ok, view, _html} = live(conn, ~p"/friends")

      html = render_click(view, "accept", %{"id" => other_request.id})

      assert html =~ "You are not allowed to do that."
    end
  end

  describe "decline" do
    setup :register_and_log_in_user

    test "declines a pending request and it disappears", %{conn: conn, user: alice} do
      bob = user_fixture()
      request = pending_friendship_fixture(bob, alice)
      {:ok, view, _html} = live(conn, ~p"/friends")

      html =
        view
        |> element("[data-test='decline-request-button'][phx-value-id='#{request.id}']")
        |> render_click()

      assert html =~ "Friend request declined."
      assert has_element?(view, "[data-test='no-pending-requests']")
      refute Social.friends?(Scope.for_user(alice), bob)
    end

    test "shows an error when declining a request not addressed to the user",
         %{conn: conn} do
      bob = user_fixture()
      carol = user_fixture()
      other_request = pending_friendship_fixture(bob, carol)
      {:ok, view, _html} = live(conn, ~p"/friends")

      html = render_click(view, "decline", %{"id" => other_request.id})

      assert html =~ "You are not allowed to do that."
    end
  end

  describe "find people (browse + search)" do
    setup :register_and_log_in_user

    test "browse lists other addable users by name", %{conn: conn} do
      other = user_fixture(%{username: "findable_user"})
      {:ok, view, _html} = live(conn, ~p"/friends")

      assert has_element?(view, "[data-test='user-result-row']")
      assert view |> element("[data-test='user-results']") |> render() =~ "findable_user"
      refute has_element?(view, "[data-test='no-users-found']")
      _ = other
    end

    test "search filters by username", %{conn: conn} do
      _match = user_fixture(%{username: "zorro_masked"})
      _miss = user_fixture(%{username: "ordinary_joe"})
      {:ok, view, _html} = live(conn, ~p"/friends")

      view
      |> form("[data-test='user-search-form']", %{"query" => "zorro"})
      |> render_change()

      results = view |> element("[data-test='user-results']") |> render()
      assert results =~ "zorro_masked"
      refute results =~ "ordinary_joe"
    end

    test "adding a user sends a request and removes them from results", %{conn: conn} do
      other = user_fixture(%{username: "future_friend"})
      {:ok, view, _html} = live(conn, ~p"/friends")

      html =
        view
        |> element("[data-test='add-friend-button'][phx-value-id='#{other.id}']")
        |> render_click()

      assert html =~ "Friend request sent."
      # No longer addable (pending), so it drops out of the results.
      refute render(view) =~ "future_friend"
    end

    test "existing friends do not appear in browse", %{conn: conn, user: me} do
      friend = user_fixture(%{username: "already_pals"})
      accepted_friendship_fixture(me, friend)
      {:ok, view, _html} = live(conn, ~p"/friends")

      # Not in the search results (they do show in the "Your friends" list).
      refute view |> element("[data-test='user-results']") |> render() =~ "already_pals"
    end
  end
end
