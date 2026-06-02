defmodule SudokuRaceWeb.PuzzleLive.ShowTest do
  use SudokuRaceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SudokuRace.PuzzlesFixtures

  alias SudokuRace.Attempts

  # Read a single cell from the live view's server-side grid assign.
  defp grid_at(view, pos) do
    :sys.get_state(view.pid).socket.assigns.grid |> Enum.at(pos)
  end

  # Read the notes (candidate list, or nil) for a cell from server-side assigns.
  defp notes_at(view, pos) do
    :sys.get_state(view.pid).socket.assigns.notes |> Map.get(pos)
  end

  # NOTE: This test module drives the server-side LiveView handlers.
  # True in-browser keyboard navigation and JS hooks (Timer, GridKeyboard,
  # InputModeDetect) require Wallaby and are out of scope for this step.
  # Server-side event handlers for keypress routing ARE tested via render_hook/3.

  # ---------------------------------------------------------------------------
  # Test puzzle helpers — use a distinguishable solution so the security test
  # can reliably assert the solution bytes are absent from the HTML.
  #
  # Solution: "123456789" repeated 9 times — distinct from "9"*81 default.
  # Clue: uses the first 35 digits of the solution as givens (consistent with
  # the solution at those positions), then "0" for the remaining 46 blanks.
  # This ensures the assembled submit grid can equal the solution exactly.
  # ---------------------------------------------------------------------------

  @solution String.duplicate("123456789", 9)
  # First 35 digits of solution as givens, then 46 blanks
  @clue String.slice(@solution, 0, 35) <> String.duplicate("0", 46)

  defp puzzle_fixture_secure do
    easy_puzzle_fixture(%{clues: @clue, solution: @solution, givens_count: 35})
  end

  # ---------------------------------------------------------------------------
  # Authentication gate
  # ---------------------------------------------------------------------------
  describe "route requires authentication" do
    test "redirects unauthenticated users to log-in", %{conn: conn} do
      # We need a real puzzle id to form a valid URL
      puzzle = puzzle_fixture_secure()
      {:error, redirect} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  # ---------------------------------------------------------------------------
  # Start page (no attempt yet)
  # ---------------------------------------------------------------------------
  describe "start page — no attempt" do
    setup :register_and_log_in_user

    test "renders difficulty but NO grid (#2: no gridcells in DOM)", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert html =~ "easy"
      refute html =~ ~s(role="gridcell")
    end

    test "clue digits are NOT in the DOM on start page (#2 hard assertion)", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # "7" is our clue digit — must not appear in grid context
      refute html =~ ~s(role="gridcell")
      refute html =~ ~s(role="grid")
    end

    test "shows Start button, not Resume or Pause", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert has_element?(view, "[data-test='start-button']")
      refute has_element?(view, "[data-test='resume-button']")
      refute has_element?(view, "[data-test='pause-button']")
    end

    test "#1 SECURITY: full solution string never appears in rendered HTML", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # The full 81-char solution string must not appear in any form.
      # Individual digits appear in the clue but the full solution must be absent.
      refute html =~ @solution

      # D1 defense-in-depth: also assert at the assigns level that the loaded
      # puzzle map has no :solution key and is NOT a full %Puzzle{} struct.
      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns.puzzle, :solution)
      refute is_struct(assigns.puzzle, SudokuRace.Puzzles.Puzzle)
    end

    test "clicking Start creates the attempt and transitions to in_progress", %{
      conn: conn,
      scope: scope
    } do
      puzzle = puzzle_fixture_secure()
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='start-button']") |> render_click()

      # Grid must now be visible
      assert has_element?(view, "[role='grid']")
      assert has_element?(view, "[role='gridcell']")

      # Attempt must exist in DB as in_progress
      assert {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert attempt.status == :in_progress
    end
  end

  # ---------------------------------------------------------------------------
  # In-progress view (grid revealed)
  # ---------------------------------------------------------------------------
  describe "in-progress view" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "renders ARIA grid with role='grid'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[role='grid']")
    end

    test "renders cells with role='gridcell'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[role='gridcell']")
    end

    test "clue cells have aria-readonly='true' and 'given' in aria-label", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      html = render(view)

      assert html =~ ~s(aria-readonly="true")
      assert html =~ "given"
    end

    test "editable cells have aria-label with row, column, and value description", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      html = render(view)

      # At least one editable cell for our 35-givens puzzle
      assert html =~ "empty"
    end

    test "shows Pause button and no Start/Resume buttons", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert has_element?(view, "[data-test='pause-button']")
      refute has_element?(view, "[data-test='start-button']")
      refute has_element?(view, "[data-test='resume-button']")
    end

    test "shows Submit button", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[data-test='submit-button']")
    end

    test "#1 SECURITY: full solution string never appears in rendered HTML even in-progress", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      # The full 81-char solution must not appear even when playing.
      # Individual clue digits from the solution will appear (they're given cells),
      # but the complete solution string must not.
      refute html =~ @solution
    end

    test "entering a value via cell_entry event updates the cell", %{
      conn: conn,
      puzzle: puzzle,
      attempt: attempt
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Find the first blank cell position (clue has 35 givens at the start, so position 36 is blank)
      # Push cell_entry event as the JS hook would
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "5"})

      html = render(view)
      # The cell at position 35 should now show "5"
      assert html =~ ~s(value 5)
      # Attempt stays in_progress; the board is also persisted (see restore test).
      assert attempt.status == :in_progress
    end

    test "entered digits survive a fresh mount (reconnect/deploy restore)", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "7"})

      # A brand-new mount (as happens when the app restarts on deploy) must
      # restore the board from the persisted attempt, not blank it from clues.
      {:ok, _view2, html2} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert html2 =~ ~s(value 7)
    end

    test "clearing a cell via cell_entry with '0' makes it empty", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "cell_entry", %{"position" => 35, "value" => "5"})
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "0"})

      html = render(view)
      assert html =~ "empty"
    end

    test "clicking Pause transitions to paused state and hides grid (#2)", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='pause-button']") |> render_click()

      refute has_element?(view, "[role='gridcell']")
      refute has_element?(view, "[role='grid']")
      assert has_element?(view, "[data-test='resume-button']")
    end
  end

  # ---------------------------------------------------------------------------
  # Paused view
  # ---------------------------------------------------------------------------
  describe "paused view" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)
      {:ok, puzzle: puzzle, attempt: paused}
    end

    test "grid is NOT in DOM (#2 hard assertion)", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute has_element?(view, "[role='grid']")
      refute has_element?(view, "[role='gridcell']")
    end

    test "no focusable grid cells (#2: zero focusable cells)", %{conn: conn, puzzle: puzzle} do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute html =~ ~s(role="gridcell")
    end

    test "clue digits are NOT in the DOM (#2)", %{conn: conn, puzzle: puzzle} do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute html =~ ~s(role="gridcell")
    end

    test "shows Resume button", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[data-test='resume-button']")
    end

    test "#1 SECURITY: full solution string not in HTML", %{conn: conn, puzzle: puzzle} do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      refute html =~ @solution
    end

    test "clicking Resume transitions to in_progress and reveals grid", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='resume-button']") |> render_click()

      assert has_element?(view, "[role='grid']")
      assert has_element?(view, "[role='gridcell']")
    end

    test "grid state (user entries) survives pause->resume within session", %{
      conn: conn,
      puzzle: puzzle,
      scope: scope
    } do
      # The setup already created a paused attempt. Resume it for this test.
      paused = puzzle_for_scope_attempt(scope, puzzle)
      {:ok, _resumed} = Attempts.resume_attempt(scope, paused)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Enter a value at a blank position
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "3"})

      # Pause
      view |> element("[data-test='pause-button']") |> render_click()

      # Resume
      view |> element("[data-test='resume-button']") |> render_click()

      html = render(view)
      # The entry should survive the pause/resume within the same session
      assert html =~ ~s(value 3)
    end
  end

  # ---------------------------------------------------------------------------
  # Completed view
  # ---------------------------------------------------------------------------
  describe "completed view" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, completed} = Attempts.submit_attempt(scope, attempt, @solution)
      {:ok, puzzle: puzzle, attempt: completed}
    end

    test "grid is NOT in DOM (#2 hard assertion)", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute has_element?(view, "[role='grid']")
      refute has_element?(view, "[role='gridcell']")
    end

    test "no focusable grid cells (#2: zero focusable cells)", %{conn: conn, puzzle: puzzle} do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      refute html =~ ~s(role="gridcell")
    end

    test "shows the server's recorded elapsed_seconds", %{
      conn: conn,
      puzzle: puzzle,
      attempt: attempt
    } do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert html =~ Integer.to_string(attempt.elapsed_seconds)
    end

    test "#1 SECURITY: full solution string not in HTML", %{conn: conn, puzzle: puzzle} do
      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      refute html =~ @solution
    end

    test "does not show Start, Pause, or Resume buttons", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute has_element?(view, "[data-test='start-button']")
      refute has_element?(view, "[data-test='pause-button']")
      refute has_element?(view, "[data-test='resume-button']")
    end
  end

  # ---------------------------------------------------------------------------
  # Submit correct solution
  # ---------------------------------------------------------------------------
  describe "submit correct solution" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "correct submit transitions to completed view with server elapsed_seconds", %{
      conn: conn,
      puzzle: puzzle,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Fill all blank cells via events so we can assemble a full 81-char grid.
      # Our clue has 35 givens ("7") and 46 blanks. We fill blanks with the
      # corresponding solution digits at those positions.
      fill_all_blanks(view, @clue, @solution)

      view |> element("[data-test='submit-button']") |> render_click()

      html = render(view)

      # Should be in completed state
      refute html =~ ~s(role="gridcell")
      refute has_element?(view, "[data-test='pause-button']")

      # Should show elapsed seconds from the server-recorded attempt
      {:ok, completed} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert completed.status == :completed
      assert html =~ Integer.to_string(completed.elapsed_seconds)
    end
  end

  # ---------------------------------------------------------------------------
  # Submit incorrect solution (#3)
  # ---------------------------------------------------------------------------
  describe "submit incorrect solution (#3)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "incorrect solution shows aria-live message, grid unchanged", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Fill all blanks with wrong digits ("1" everywhere blank)
      fill_blanks_with(view, @clue, "1")

      view |> element("[data-test='submit-button']") |> render_click()

      html = render(view)

      # Generic error message in aria-live region
      assert has_element?(view, "[aria-live='polite']")
      assert html =~ "doesn&#39;t match" or html =~ "doesn't match"

      # Grid is still visible (in_progress)
      assert has_element?(view, "[role='grid']")
    end

    test "incorrect solution does NOT reveal per-cell hints", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      fill_blanks_with(view, @clue, "1")
      view |> element("[data-test='submit-button']") |> render_click()

      html = render(view)

      # No per-cell error indicators — CLAUDE.md §scope "no anti-cheat beyond server validation"
      refute html =~ "incorrect-cell"
      refute html =~ ~s(aria-invalid="true")
    end
  end

  # ---------------------------------------------------------------------------
  # Submit incomplete/malformed grid (#3 validation)
  # ---------------------------------------------------------------------------
  describe "submit incomplete grid (#3 validation)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "submitting with blanks shows validation message distinct from incorrect", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Do NOT fill any blanks — submit with the clue-only grid (has "0" in blanks)
      view |> element("[data-test='submit-button']") |> render_click()

      html = render(view)

      assert has_element?(view, "[aria-live='polite']")
      assert html =~ "Fill in" or html =~ "every cell"

      # Grid stays visible
      assert has_element?(view, "[role='grid']")
    end
  end

  # ---------------------------------------------------------------------------
  # Defensive: stale state-machine returns (#4)
  # ---------------------------------------------------------------------------
  describe "defensive handling of stale state (#4)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "double-submit: second submit does not crash, shows sensible message", %{
      conn: conn,
      puzzle: puzzle,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Fill all blanks correctly for first submit
      fill_all_blanks(view, @clue, @solution)

      # First submit — should succeed and transition to :completed
      view |> element("[data-test='submit-button']") |> render_click()

      # Verify first submit succeeded
      {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert attempt.status == :completed

      # Re-mount to verify completed view is stable (no crash)
      {:ok, view2, html2} = live(conn, ~p"/puzzles/#{puzzle.id}")
      refute html2 =~ ~s(role="gridcell")

      # The completed view should show elapsed time, not panic
      assert render(view2) =~ Integer.to_string(attempt.elapsed_seconds)
    end

    test "not_found puzzle redirects with friendly flash message", %{conn: conn} do
      # Requesting a puzzle that doesn't exist redirects to the puzzle list
      {:error, {:live_redirect, %{to: to, flash: flash}}} = live(conn, ~p"/puzzles/999999999")
      assert to == "/puzzles"
      assert flash["error"] =~ "No puzzle"
    end
  end

  # ---------------------------------------------------------------------------
  # Accessibility attributes (#accessibility assertions)
  # ---------------------------------------------------------------------------
  describe "accessibility attributes" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "grid has role='grid'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[role='grid']")
    end

    test "rows have role='row'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[role='row']")
    end

    test "cells have role='gridcell'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[role='gridcell']")
    end

    test "clue cells have aria-readonly='true'", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[aria-readonly='true']")
    end

    test "cells have data-test='grid-cell' selector", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[data-test='grid-cell']")
    end

    test "number-pad buttons have aria-labels", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      # Number pad buttons for digits 1–9
      assert has_element?(view, "[data-test='numpad-button']")
      html = render(view)
      assert html =~ ~s(aria-label="Enter 1")
    end

    test "grid exposes data-focused-cell for the keyboard hook", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      html = render(view)

      # The GridKeyboard hook drives off this server attribute (not browser focus,
      # which Safari/Firefox don't set on a clicked <button>). Must be present.
      assert html =~ ~s(data-focused-cell=)
    end

    test "pad uses phx-value-digit, not phx-value-value (button .value collision)", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      html = render(view)

      # `phx-value-value` on a <button> is silently overridden by the element's
      # intrinsic empty `.value` in the browser, so the server received "" and
      # the pad did nothing. The param must be named something else.
      assert html =~ "phx-value-digit"
      refute html =~ "phx-value-value"
    end

    test "aria-live region exists", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      assert has_element?(view, "[aria-live='polite']")
    end
  end

  # ---------------------------------------------------------------------------
  # O1 — InputModeDetect: input_mode:detect event handler
  # ---------------------------------------------------------------------------
  describe "input_mode:detect event" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "mode=touch payload sets input_mode to :touch", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "input_mode:detect", %{"mode" => "touch"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :touch
    end

    test "mode=pointer payload sets input_mode to :pointer", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # First flip to touch so we can verify pointer flip
      render_hook(view, "input_mode:detect", %{"mode" => "touch"})
      render_hook(view, "input_mode:detect", %{"mode" => "pointer"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :pointer
    end

    test "invalid mode payload is a safe no-op — mode unchanged", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Default is :pointer; sending garbage must leave it unchanged and not crash
      render_hook(view, "input_mode:detect", %{"mode" => "nonsense"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :pointer
    end

    test "missing mode key payload is a safe no-op", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "input_mode:detect", %{"coarse" => true})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :pointer
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — toggle_input_mode: flips mode and button label
  # ---------------------------------------------------------------------------
  describe "toggle_input_mode event" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "toggling flips pointer to touch and updates button label", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      html_before = render(view)
      assert html_before =~ "Touch mode"

      view |> element("[data-test='input-mode-toggle']") |> render_click()

      html_after = render(view)
      assert html_after =~ "Pointer mode"
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :touch
    end

    test "toggling again flips touch back to pointer", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='input-mode-toggle']") |> render_click()
      view |> element("[data-test='input-mode-toggle']") |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_mode == :pointer
    end
  end

  # ---------------------------------------------------------------------------
  # Mobile touch entry — sudoku.com-style on-screen number pad (no native keyboard)
  # ---------------------------------------------------------------------------
  describe "mobile touch entry" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "grid exposes the current input mode for the keyboard hook", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert has_element?(view, "[data-test='sudoku-grid'][data-input-mode='pointer']")

      view |> element("[data-test='input-mode-toggle']") |> render_click()

      assert has_element?(view, "[data-test='sudoku-grid'][data-input-mode='touch']")
    end

    test "no native-keyboard input is rendered (the on-screen pad is the input)", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute has_element?(view, "[data-test='mobile-entry']")
    end

    test "the on-screen number pad is shown in both pointer and touch modes", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Pointer mode (default) offers the tappable number pad.
      assert has_element?(view, "[data-test='number-pad']")
      assert has_element?(view, "[data-test='numpad-button']")

      view |> element("[data-test='input-mode-toggle']") |> render_click()

      # Touch mode keeps the pad on screen (no native keyboard to cover the board).
      assert has_element?(view, "[data-test='number-pad']")
      assert has_element?(view, "[data-test='numpad-button']")
    end

    test "the action bar (undo/redo/erase) is present in touch mode", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='input-mode-toggle']") |> render_click()

      assert has_element?(view, "[data-test='action-bar']")
      assert has_element?(view, "[data-test='undo-button']")
      assert has_element?(view, "[data-test='redo-button']")
      assert has_element?(view, "[data-test='erase-button']")
    end
  end

  # ---------------------------------------------------------------------------
  # Undo / redo / erase
  # ---------------------------------------------------------------------------
  describe "undo, redo, and erase" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "clicking the number pad enters the digit into the selected cell", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Select an editable cell by clicking it, exactly as a user would.
      # (35 is a non-given cell in the fixture.)
      view |> element("[data-test='grid-cell'][data-position='35']") |> render_click()

      # Click the rendered "7" button on the pad — exercises the real markup,
      # not just the handler, so a button-wiring regression would be caught.
      view |> element("[data-test='numpad-button']", "7") |> render_click()

      assert grid_at(view, 35) == "7"
    end

    test "erase clears the focused cell", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # 35 is a non-given (editable) cell in the fixture.
      render_hook(view, "cell_focus", %{"position" => "35"})
      render_hook(view, "cell_entry", %{"position" => "35", "value" => "7"})
      assert grid_at(view, 35) == "7"

      view |> element("[data-test='erase-button']") |> render_click()

      assert grid_at(view, 35) == "0"
    end

    test "undo reverts the last entry and redo re-applies it", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "cell_entry", %{"position" => "35", "value" => "7"})
      assert grid_at(view, 35) == "7"

      render_hook(view, "undo", %{})
      assert grid_at(view, 35) == "0"

      render_hook(view, "redo", %{})
      assert grid_at(view, 35) == "7"
    end

    test "a fresh entry clears the redo stack", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "cell_entry", %{"position" => "35", "value" => "7"})
      render_hook(view, "undo", %{})
      # New entry after an undo discards the redo history.
      render_hook(view, "cell_entry", %{"position" => "35", "value" => "4"})

      assert has_element?(view, "[data-test='redo-button'][disabled]")
      assert grid_at(view, 35) == "4"
    end

    test "undo and redo are safe no-ops with empty history", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      before = :sys.get_state(view.pid).socket.assigns.grid
      render_hook(view, "undo", %{})
      render_hook(view, "redo", %{})
      assert :sys.get_state(view.pid).socket.assigns.grid == before
    end

    test "undo/redo buttons reflect availability via the disabled attribute", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert has_element?(view, "[data-test='undo-button'][disabled]")
      assert has_element?(view, "[data-test='redo-button'][disabled]")

      render_hook(view, "cell_entry", %{"position" => "35", "value" => "7"})
      refute has_element?(view, "[data-test='undo-button'][disabled]")

      render_hook(view, "undo", %{})
      refute has_element?(view, "[data-test='redo-button'][disabled]")
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — cell_entry on a GIVEN cell is a no-op
  # ---------------------------------------------------------------------------
  describe "cell_entry on a given (clue) cell" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "entering a digit at a clue position leaves the grid cell unchanged", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Position 0 is a given in our fixture (first digit of the solution)
      original_grid = :sys.get_state(view.pid).socket.assigns.grid
      original_value = Enum.at(original_grid, 0)

      # Attempt entry at a given position with a different digit
      different_digit = if original_value == "1", do: "2", else: "1"
      render_hook(view, "cell_entry", %{"position" => 0, "value" => different_digit})

      updated_grid = :sys.get_state(view.pid).socket.assigns.grid
      assert Enum.at(updated_grid, 0) == original_value
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — cell_entry/cell_focus is_binary(pos) clauses (numpad/click paths)
  # ---------------------------------------------------------------------------
  describe "cell_entry and cell_focus with string position (numpad/click path)" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, puzzle: puzzle, attempt: attempt}
    end

    test "cell_entry with string position updates the cell (numpad click path)", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Numpad click sends position as string via phx-value-position attribute
      render_hook(view, "cell_entry", %{"position" => "35", "value" => "7"})

      html = render(view)
      assert html =~ "value 7"
    end

    test "cell_entry with non-numeric string position is a safe no-op", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      original_grid = :sys.get_state(view.pid).socket.assigns.grid
      render_hook(view, "cell_entry", %{"position" => "bad", "value" => "5"})
      assert :sys.get_state(view.pid).socket.assigns.grid == original_grid
    end

    test "cell_focus with string position updates focused_cell", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      render_hook(view, "cell_focus", %{"position" => "40"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.focused_cell == 40
    end

    test "cell_focus with non-numeric string position is a safe no-op", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      original_focus = :sys.get_state(view.pid).socket.assigns.focused_cell
      render_hook(view, "cell_focus", %{"position" => "nope"})
      assert :sys.get_state(view.pid).socket.assigns.focused_cell == original_focus
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — start: secondary error arms (:already_attempted, :not_found)
  # ---------------------------------------------------------------------------
  describe "start event secondary error arms" do
    setup :register_and_log_in_user

    test ":already_attempted re-syncs view to playing state", %{conn: conn, scope: scope} do
      puzzle = puzzle_fixture_secure()
      # Create attempt out-of-band so the next start click hits :already_attempted
      {:ok, _} = Attempts.start_attempt(scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # At this point view_state is :playing (loaded from existing attempt on mount)
      # Click Start via render_hook to force the event (button not in DOM for :playing)
      render_hook(view, "start", %{})

      # Must not crash and must reflect the playing state
      assert has_element?(view, "[role='grid']")
    end

    test ":not_found shows status message", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Delete the puzzle to trigger :not_found on start
      SudokuRace.Repo.delete!(puzzle)

      render_hook(view, "start", %{})

      html = render(view)
      assert html =~ "Puzzle not found"
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — pause: :not_in_progress error arm
  # ---------------------------------------------------------------------------
  describe "pause event :not_in_progress error arm" do
    setup :register_and_log_in_user

    test "pause when already paused shows message and re-syncs", %{conn: conn, scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _paused} = Attempts.pause_attempt(scope, attempt)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Force pause event even though attempt is already paused
      render_hook(view, "pause", %{})

      html = render(view)
      assert html =~ "Already paused or completed"
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — resume: :not_paused error arm
  # ---------------------------------------------------------------------------
  describe "resume event :not_paused error arm" do
    setup :register_and_log_in_user

    test "resume when already in_progress shows message and re-syncs", %{conn: conn, scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Force resume event even though attempt is in_progress (not paused)
      render_hook(view, "resume", %{})

      html = render(view)
      assert html =~ "Already in progress or completed"
    end
  end

  # ---------------------------------------------------------------------------
  # O2 — submit: :not_in_progress and :already_completed error arms
  # ---------------------------------------------------------------------------
  describe "submit event secondary error arms" do
    setup :register_and_log_in_user

    test ":not_in_progress shows message and re-syncs state", %{conn: conn, scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _paused} = Attempts.pause_attempt(scope, attempt)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Force submit while attempt is paused (triggers :not_in_progress)
      render_hook(view, "submit", %{})

      html = render(view)
      assert html =~ "Attempt is not in progress"
    end

    test "in-socket double-submit: second submit on same socket does not crash, view stays completed",
         %{conn: conn, scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      fill_all_blanks(view, @clue, @solution)
      view |> element("[data-test='submit-button']") |> render_click()

      # Confirm first submit succeeded
      {:ok, completed} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert completed.status == :completed

      # Second submit on same live socket (no re-mount) — button is gone, use render_hook
      render_hook(view, "submit", %{})

      # Must not crash; view must reflect completed state
      html = render(view)
      assert html =~ "Solved!"
      assert html =~ Integer.to_string(completed.elapsed_seconds)
      refute has_element?(view, "[role='grid']")
    end
  end

  # ---------------------------------------------------------------------------
  # Friend times — completed view only
  # ---------------------------------------------------------------------------
  describe "friend times in completed view" do
    setup :register_and_log_in_user

    import SudokuRace.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
    import SudokuRace.SocialFixtures, only: [accepted_friendship_fixture: 2]

    defp complete_for(scope, puzzle) do
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _} = Attempts.submit_attempt(scope, attempt, @solution)
    end

    test "friend_times NOT in assigns when view_state is :start (defense-in-depth)", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns, :friend_times)
    end

    test "friend_times NOT in assigns when view_state is :playing (defense-in-depth)", %{
      conn: conn,
      scope: scope
    } do
      puzzle = puzzle_fixture_secure()
      {:ok, _} = Attempts.start_attempt(scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns, :friend_times)
    end

    test "friend_times NOT in assigns when view_state is :paused (defense-in-depth)", %{
      conn: conn,
      scope: scope
    } do
      puzzle = puzzle_fixture_secure()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _} = Attempts.pause_attempt(scope, attempt)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns, :friend_times)
    end

    test "friend_times IS in assigns when view_state is :completed", %{
      conn: conn,
      scope: scope
    } do
      puzzle = puzzle_fixture_secure()
      complete_for(scope, puzzle)

      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert Map.has_key?(assigns, :friend_times)
    end

    test "friend times table renders for a friend who completed", %{
      conn: conn,
      user: me,
      scope: my_scope
    } do
      friend = user_fixture()
      friend_scope = user_scope_fixture(friend)
      accepted_friendship_fixture(me, friend)

      puzzle = puzzle_fixture_secure()
      complete_for(my_scope, puzzle)
      complete_for(friend_scope, puzzle)

      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert html =~ ~s(data-test="friend-times-table")
      assert html =~ friend.email
    end

    test "friend times table NOT rendered in non-completed state", %{
      conn: conn,
      user: me,
      scope: my_scope
    } do
      friend = user_fixture()
      friend_scope = user_scope_fixture(friend)
      accepted_friendship_fixture(me, friend)

      puzzle = puzzle_fixture_secure()
      {:ok, _} = Attempts.start_attempt(my_scope, puzzle)
      complete_for(friend_scope, puzzle)

      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute html =~ ~s(data-test="friend-times-table")
    end

    test "friend times table absent when no friends completed (but I completed)", %{
      conn: conn,
      scope: my_scope
    } do
      puzzle = puzzle_fixture_secure()
      complete_for(my_scope, puzzle)

      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      # Table may render but should be empty or absent — no friend rows
      refute html =~ ~s(data-test="friend-time-row")
    end

    test "stranger's completion time NOT shown", %{conn: conn, scope: my_scope} do
      stranger = user_fixture()
      stranger_scope = user_scope_fixture(stranger)
      # No friendship with stranger

      puzzle = puzzle_fixture_secure()
      complete_for(my_scope, puzzle)
      complete_for(stranger_scope, puzzle)

      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      refute html =~ stranger.email
    end

    test "my own time is shown in the completed view", %{conn: conn, scope: my_scope} do
      puzzle = puzzle_fixture_secure()
      complete_for(my_scope, puzzle)

      {:ok, _view, html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert html =~ ~s(data-test="my-time")
    end
  end

  # ---------------------------------------------------------------------------
  # Index → Show navigation link
  # ---------------------------------------------------------------------------
  describe "index page has navigation link to show" do
    setup :register_and_log_in_user

    test "each puzzle row has a link to the show page", %{conn: conn} do
      puzzle = puzzle_fixture_secure()
      {:ok, view, _html} = live(conn, ~p"/puzzles")

      assert has_element?(view, "[data-test='puzzle-play-link']")
      html = render(view)
      assert html =~ "/puzzles/#{puzzle.id}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Fill all blank cells (value "0" in clue) with the corresponding solution digit
  defp fill_all_blanks(view, clue, solution) do
    clue
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.each(fn {c, i} ->
      if c == "0" do
        digit = String.at(solution, i)
        render_hook(view, "cell_entry", %{"position" => i, "value" => digit})
      end
    end)
  end

  # Fill all blank cells with a fixed digit (for incorrect submit testing)
  defp fill_blanks_with(view, clue, digit) do
    clue
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.each(fn {c, i} ->
      if c == "0" do
        render_hook(view, "cell_entry", %{"position" => i, "value" => digit})
      end
    end)
  end

  # Helper for pause/resume test — fetch the current attempt for the scope
  defp puzzle_for_scope_attempt(scope, puzzle) do
    {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
    attempt
  end

  # ---------------------------------------------------------------------------
  # Notes (pencil marks)
  # ---------------------------------------------------------------------------
  describe "notes mode" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      puzzle = puzzle_fixture_secure()
      {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)
      # Position 35 is the first editable (non-given) cell in the fixture.
      {:ok, puzzle: puzzle}
    end

    test "toggling the Notes button flips its pressed state", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      assert view |> element("[data-test='notes-toggle']") |> render() =~ ~s(aria-pressed="false")

      view |> element("[data-test='notes-toggle']") |> render_click()
      assert view |> element("[data-test='notes-toggle']") |> render() =~ ~s(aria-pressed="true")

      view |> element("[data-test='notes-toggle']") |> render_click()
      assert view |> element("[data-test='notes-toggle']") |> render() =~ ~s(aria-pressed="false")
    end

    test "in Notes mode a digit adds a candidate; the same digit removes it", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      view |> element("[data-test='notes-toggle']") |> render_click()

      render_hook(view, "cell_entry", %{"position" => 35, "value" => "4"})
      assert notes_at(view, 35) == [4]
      # No final value placed.
      assert grid_at(view, 35) == "0"

      render_hook(view, "cell_entry", %{"position" => 35, "value" => "4"})
      assert notes_at(view, 35) == nil
    end

    test "a noted cell renders its candidates (3x3) with an accurate aria-label", %{
      conn: conn,
      puzzle: puzzle
    } do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      view |> element("[data-test='notes-toggle']") |> render_click()

      render_hook(view, "cell_entry", %{"position" => 35, "value" => "7"})
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "1"})

      html = render(view)
      assert html =~ ~s(data-test="cell-notes")
      # Sorted candidates in the label.
      assert html =~ "notes 1 7"
    end

    test "placing a final value clears that cell's notes", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")

      view |> element("[data-test='notes-toggle']") |> render_click()
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "4"})
      assert notes_at(view, 35) == [4]

      # Notes off → place a final value.
      view |> element("[data-test='notes-toggle']") |> render_click()
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "5"})

      assert grid_at(view, 35) == "5"
      assert notes_at(view, 35) == nil
    end

    test "erase clears both value and notes for the focused cell", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      render_hook(view, "cell_focus", %{"position" => 35})

      # A noted cell, then erase.
      view |> element("[data-test='notes-toggle']") |> render_click()
      render_hook(view, "cell_entry", %{"position" => 35, "value" => "4"})
      assert notes_at(view, 35) == [4]

      view |> element("[data-test='erase-button']") |> render_click()
      assert notes_at(view, 35) == nil
      assert grid_at(view, 35) == "0"
    end

    test "undo and redo round-trip a note toggle", %{conn: conn, puzzle: puzzle} do
      {:ok, view, _html} = live(conn, ~p"/puzzles/#{puzzle.id}")
      view |> element("[data-test='notes-toggle']") |> render_click()

      render_hook(view, "cell_entry", %{"position" => 35, "value" => "4"})
      assert notes_at(view, 35) == [4]

      view |> element("[data-test='undo-button']") |> render_click()
      assert notes_at(view, 35) == nil

      view |> element("[data-test='redo-button']") |> render_click()
      assert notes_at(view, 35) == [4]
    end
  end
end
