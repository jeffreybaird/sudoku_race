defmodule Mix.Tasks.SudokuRace.GrantAdminTest do
  use SudokuRace.DataCase, async: true

  import ExUnit.CaptureIO
  import SudokuRace.AccountsFixtures

  alias Mix.Tasks.SudokuRace.GrantAdmin
  alias SudokuRace.Accounts

  test "grants admin to an existing user" do
    user = user_fixture()
    refute user.is_admin

    capture_io(fn -> GrantAdmin.run([user.email]) end)

    assert Accounts.get_user!(user.id).is_admin
  end

  test "raises for an unknown email" do
    assert_raise Mix.Error, fn -> GrantAdmin.run(["nobody@example.com"]) end
  end

  test "raises usage on missing argument" do
    assert_raise Mix.Error, fn -> GrantAdmin.run([]) end
  end
end
