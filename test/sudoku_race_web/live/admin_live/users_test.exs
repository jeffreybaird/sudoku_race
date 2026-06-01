defmodule SudokuRaceWeb.AdminLive.UsersTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.AccountsFixtures

  alias SudokuRace.Accounts

  describe "access control" do
    test "redirects unauthenticated users to log-in", %{conn: conn} do
      {:error, redirect} = live(conn, ~p"/admin/users")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "redirects a logged-in non-admin away", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:error, redirect} = live(conn, ~p"/admin/users")
      assert {:redirect, %{to: "/"}} = redirect
    end

    test "an admin can load the page", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())
      {:ok, _view, html} = live(conn, ~p"/admin/users")
      assert html =~ "User administration"
    end

    test "redirects an admin whose sudo has expired to re-authenticate", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())
      # Age the session past the 10-minute sudo window.
      conn |> get_session(:user_token) |> offset_user_token(-20, :minute)

      {:error, redirect} = live(conn, ~p"/admin/users")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  describe "reset password" do
    setup %{conn: conn} do
      admin = admin_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "lists users with a reset form", %{conn: conn} do
      target = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "[data-test='admin-user-row']")
      assert view |> element("[data-test='admin-user-list']") |> render() =~ target.email
    end

    test "resets a user's password", %{conn: conn} do
      target = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> form("#reset-form-#{target.id}", %{"password" => "a brand new password"})
        |> render_submit()

      assert html =~ "Password reset for #{target.email}."
      assert Accounts.get_user_by_email_and_password(target.email, "a brand new password")
    end

    test "shows an error for an invalid password", %{conn: conn} do
      target = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      html =
        view
        |> form("#reset-form-#{target.id}", %{"password" => "x"})
        |> render_submit()

      assert html =~ "should be at least 12 character"
      # Unchanged.
      assert Accounts.get_user_by_email_and_password(target.email, valid_user_password())
    end
  end
end
