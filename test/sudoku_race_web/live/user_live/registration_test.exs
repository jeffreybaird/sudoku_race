defmodule SudokuRaceWeb.UserLive.RegistrationTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.AccountsFixtures

  describe "Registration page" do
    test "renders registration page with email, username, and password fields", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
      assert html =~ ~s(name="user[email]")
      assert html =~ ~s(name="user[username]")
      assert html =~ ~s(name="user[password]")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces", "password" => "short"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "should be at least 12 character"
    end
  end

  describe "register user" do
    test "registers with email + password and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      # Logged in → bounced to the signed-in landing.
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)

      user = SudokuRace.Accounts.get_user_by_email(email)
      assert user.confirmed_at
    end

    test "accepts an optional username", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, username: "racer_one")
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/"

      assert SudokuRace.Accounts.get_user_by_email(email).username == "racer_one"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: valid_user_attributes(email: user.email)
        )
        |> render_submit()

      assert result =~ "has already been taken"
      # Security: a failed registration must not echo the password back into the
      # DOM, and must not auto-submit (trigger_action) to the session controller.
      refute result =~ valid_user_password()
      refute result =~ ~s(phx-trigger-action)
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
