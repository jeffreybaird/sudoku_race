defmodule SudokuRace.AttemptsTest do
  use SudokuRace.DataCase, async: true

  alias SudokuRace.Attempts
  alias SudokuRace.Attempts.Attempt

  import SudokuRace.AccountsFixtures
  import SudokuRace.PuzzlesFixtures

  # ---------------------------------------------------------------------------
  # Doctest execution — pure functions only
  # ---------------------------------------------------------------------------
  doctest Attempts, only: [elapsed_seconds: 2]

  # ---------------------------------------------------------------------------
  # elapsed_seconds/2 — pure function unit tests (beyond doctests)
  # ---------------------------------------------------------------------------
  describe "elapsed_seconds/2 — pure function" do
    test "running attempt: accumulated + current segment" do
      now = ~U[2024-01-01 00:01:00Z]
      segment_start = ~U[2024-01-01 00:00:00Z]

      attempt = %Attempt{
        status: :in_progress,
        accumulated_seconds: 10,
        segment_started_at: segment_start,
        elapsed_seconds: nil
      }

      # 10 accumulated + 60 current segment
      assert Attempts.elapsed_seconds(attempt, now) == 70
    end

    test "paused attempt: only accumulated_seconds" do
      now = ~U[2024-01-01 00:01:00Z]

      attempt = %Attempt{
        status: :paused,
        accumulated_seconds: 42,
        segment_started_at: nil,
        elapsed_seconds: nil
      }

      assert Attempts.elapsed_seconds(attempt, now) == 42
    end

    test "completed attempt: returns the frozen elapsed_seconds column" do
      now = ~U[2024-01-01 00:01:00Z]

      attempt = %Attempt{
        status: :completed,
        accumulated_seconds: 100,
        segment_started_at: nil,
        elapsed_seconds: 150
      }

      assert Attempts.elapsed_seconds(attempt, now) == 150
    end

    test "running attempt: zero accumulated + just-started segment" do
      now = ~U[2024-01-01 00:00:30Z]
      segment_start = ~U[2024-01-01 00:00:00Z]

      attempt = %Attempt{
        status: :in_progress,
        accumulated_seconds: 0,
        segment_started_at: segment_start,
        elapsed_seconds: nil
      }

      assert Attempts.elapsed_seconds(attempt, now) == 30
    end
  end

  # ---------------------------------------------------------------------------
  # start_attempt/2
  # ---------------------------------------------------------------------------
  describe "start_attempt/2" do
    test "creates an in_progress attempt with correct timing fields" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      assert {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      assert attempt.status == :in_progress
      assert attempt.user_id == scope.user.id
      assert attempt.puzzle_id == puzzle.id
      assert %DateTime{} = attempt.started_at
      assert %DateTime{} = attempt.segment_started_at
      assert attempt.accumulated_seconds == 0
      assert is_nil(attempt.elapsed_seconds)
      assert is_nil(attempt.completed_at)
    end

    test "returns {:error, :already_attempted} via CONSTRAINT path when called twice" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      assert {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)
      # Second call must hit the DB and map the unique constraint violation
      assert {:error, :already_attempted} = Attempts.start_attempt(scope, puzzle)
    end

    test "returns {:error, :not_found} for a missing puzzle" do
      scope = user_scope_fixture()
      missing_puzzle = %SudokuRace.Puzzles.Puzzle{id: 999_999_999}

      assert {:error, :not_found} = Attempts.start_attempt(scope, missing_puzzle)
    end

    test "different users can each start an attempt on the same puzzle" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      assert {:ok, _} = Attempts.start_attempt(scope1, puzzle)
      assert {:ok, _} = Attempts.start_attempt(scope2, puzzle)
    end
  end

  # ---------------------------------------------------------------------------
  # pause_attempt/2
  # ---------------------------------------------------------------------------
  describe "pause_attempt/2" do
    test "pauses an in_progress attempt and accumulates elapsed seconds" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, paused} = Attempts.pause_attempt(scope, attempt)
      assert paused.status == :paused
      assert is_nil(paused.segment_started_at)
      assert paused.accumulated_seconds >= 0
      # elapsed_seconds column must still be nil — only written on completion
      assert is_nil(paused.elapsed_seconds)
    end

    test "accumulated_seconds on pause accounts for the running segment" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      # Manually back-date the segment_started_at so we get a deterministic diff
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      past = DateTime.add(DateTime.utc_now(), -120, :second)

      {:ok, backdated} =
        attempt
        |> Attempt.update_changeset(%{
          accumulated_seconds: 30,
          segment_started_at: past
        })
        |> SudokuRace.Repo.update()

      {:ok, paused} = Attempts.pause_attempt(scope, backdated)
      # 30 accumulated + ~120 segment = at least 145
      assert paused.accumulated_seconds >= 145
    end

    test "returns {:error, :not_in_progress} when attempt is already paused" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)

      assert {:error, :not_in_progress} = Attempts.pause_attempt(scope, paused)
    end

    test "returns {:error, :not_in_progress} when attempt is completed" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      solution = String.duplicate("9", 81)
      {:ok, completed} = Attempts.submit_attempt(scope, attempt, solution)

      assert {:error, :not_in_progress} = Attempts.pause_attempt(scope, completed)
    end

    test "returns {:error, :forbidden} for a non-owner" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:error, :forbidden} = Attempts.pause_attempt(other_scope, attempt)
    end

    test "accepts attempt id (integer) as second argument" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, paused} = Attempts.pause_attempt(scope, attempt.id)
      assert paused.status == :paused
    end
  end

  # ---------------------------------------------------------------------------
  # resume_attempt/2
  # ---------------------------------------------------------------------------
  describe "resume_attempt/2" do
    test "resumes a paused attempt and sets segment_started_at" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)

      assert {:ok, resumed} = Attempts.resume_attempt(scope, paused)
      assert resumed.status == :in_progress
      assert %DateTime{} = resumed.segment_started_at
    end

    test "returns {:error, :not_paused} when attempt is in_progress" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:error, :not_paused} = Attempts.resume_attempt(scope, attempt)
    end

    test "returns {:error, :not_paused} when attempt is completed" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      solution = String.duplicate("9", 81)
      {:ok, completed} = Attempts.submit_attempt(scope, attempt, solution)

      assert {:error, :not_paused} = Attempts.resume_attempt(scope, completed)
    end

    test "returns {:error, :forbidden} for a non-owner" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)

      assert {:error, :forbidden} = Attempts.resume_attempt(other_scope, paused)
    end

    test "accepts attempt id (integer) as second argument" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)

      assert {:ok, resumed} = Attempts.resume_attempt(scope, paused.id)
      assert resumed.status == :in_progress
    end
  end

  # ---------------------------------------------------------------------------
  # submit_attempt/3
  # ---------------------------------------------------------------------------
  describe "submit_attempt/3" do
    @solution String.duplicate("9", 81)
    @wrong_solution String.duplicate("1", 81)
    @bad_solution "not-81-digits"

    test "correct solution completes the attempt and records elapsed_seconds" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, completed} = Attempts.submit_attempt(scope, attempt, @solution)
      assert completed.status == :completed
      assert is_integer(completed.elapsed_seconds)
      assert completed.elapsed_seconds >= 0
      assert %DateTime{} = completed.completed_at
      assert is_nil(completed.segment_started_at)
    end

    test "elapsed_seconds is nil before completion and set on completion" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      assert is_nil(attempt.elapsed_seconds)

      {:ok, paused} = Attempts.pause_attempt(scope, attempt)
      assert is_nil(paused.elapsed_seconds)

      {:ok, resumed} = Attempts.resume_attempt(scope, paused)
      assert is_nil(resumed.elapsed_seconds)

      {:ok, completed} = Attempts.submit_attempt(scope, resumed, @solution)
      assert is_integer(completed.elapsed_seconds)
    end

    test "elapsed_seconds is computed server-side (not from any client input)" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      # submit_attempt takes only scope, attempt, and solution — no client duration
      # The function signature itself enforces this contract
      assert {:ok, completed} = Attempts.submit_attempt(scope, attempt, @solution)
      assert is_integer(completed.elapsed_seconds)
    end

    test "incorrect solution returns {:error, :incorrect_solution} and leaves attempt unchanged" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:error, :incorrect_solution} =
               Attempts.submit_attempt(scope, attempt, @wrong_solution)

      # Attempt must be unchanged
      {:ok, unchanged} = Attempts.get_attempt(scope, attempt.id)
      assert unchanged.status == :in_progress
      assert is_nil(unchanged.elapsed_seconds)
      assert is_nil(unchanged.completed_at)
    end

    test "malformed solution (not 81 digits) returns {:error, :validation, changeset}" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:error, :validation, changeset} =
               Attempts.submit_attempt(scope, attempt, @bad_solution)

      assert %Ecto.Changeset{} = changeset
    end

    test "malformed solution with correct length but non-digits returns validation error" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      # 81 chars but contains letters
      bad = String.duplicate("x", 81)

      assert {:error, :validation, _changeset} = Attempts.submit_attempt(scope, attempt, bad)
    end

    test "submit from paused returns {:error, :not_in_progress}" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, attempt)

      assert {:error, :not_in_progress} = Attempts.submit_attempt(scope, paused, @solution)
      # Attempt must still be paused
      {:ok, still_paused} = Attempts.get_attempt(scope, paused.id)
      assert still_paused.status == :paused
    end

    test "submit on already completed returns {:error, :already_completed}" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, completed} = Attempts.submit_attempt(scope, attempt, @solution)

      assert {:error, :already_completed} = Attempts.submit_attempt(scope, completed, @solution)
    end

    test "returns {:error, :forbidden} for a non-owner" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:error, :forbidden} = Attempts.submit_attempt(other_scope, attempt, @solution)
    end

    test "accepts attempt id (integer) as second argument" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: @solution})
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, completed} = Attempts.submit_attempt(scope, attempt.id, @solution)
      assert completed.status == :completed
    end
  end

  # ---------------------------------------------------------------------------
  # get_owner_attempt_for_puzzle/2
  # ---------------------------------------------------------------------------
  describe "get_owner_attempt_for_puzzle/2" do
    test "returns {:ok, attempt} for an in_progress attempt owned by the scope user" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, started} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert attempt.id == started.id
      assert attempt.status == :in_progress
    end

    test "returns {:ok, attempt} for a paused attempt owned by the scope user" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, started} = Attempts.start_attempt(scope, puzzle)
      {:ok, paused} = Attempts.pause_attempt(scope, started)

      assert {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert attempt.id == paused.id
      assert attempt.status == :paused
    end

    test "returns {:ok, attempt} for a completed attempt owned by the scope user" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})
      {:ok, started} = Attempts.start_attempt(scope, puzzle)
      {:ok, completed} = Attempts.submit_attempt(scope, started, String.duplicate("9", 81))

      assert {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert attempt.id == completed.id
      assert attempt.status == :completed
    end

    test "returns {:error, :not_found} when no attempt exists for this puzzle" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
    end

    test "returns {:error, :not_found} when another user has an attempt but the scope user does not" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, _} = Attempts.start_attempt(other_scope, puzzle)

      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
    end

    test "returns full Attempt struct with timing fields (solver's own attempt)" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, _} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, attempt} = Attempts.get_owner_attempt_for_puzzle(scope, puzzle.id)
      assert is_struct(attempt, Attempt)
      assert %DateTime{} = attempt.started_at
      assert is_integer(attempt.accumulated_seconds)
    end

    test "accepts string numeric puzzle_id and resolves to the attempt" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, started} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, attempt} =
               Attempts.get_owner_attempt_for_puzzle(scope, Integer.to_string(puzzle.id))

      assert attempt.id == started.id
    end

    test "returns {:error, :not_found} for non-numeric string puzzle_id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, "abc")
    end

    test "returns {:error, :not_found} for empty string puzzle_id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, "")
    end

    test "returns {:error, :not_found} for out-of-range string puzzle_id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} =
               Attempts.get_owner_attempt_for_puzzle(scope, "99999999999999")
    end

    test "returns {:error, :not_found} for non-positive string puzzle_id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, "0")
      assert {:error, :not_found} = Attempts.get_owner_attempt_for_puzzle(scope, "-1")
    end
  end

  # ---------------------------------------------------------------------------
  # get_active_attempt/2
  # ---------------------------------------------------------------------------
  describe "get_active_attempt/2" do
    test "returns bare :in_progress atom for an in_progress attempt" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)

      result = Attempts.get_active_attempt(scope, puzzle)
      assert result == :in_progress
    end

    test "returns bare :paused atom for a paused attempt" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _paused} = Attempts.pause_attempt(scope, attempt)

      result = Attempts.get_active_attempt(scope, puzzle)
      assert result == :paused
    end

    test "returns nil when no attempt exists for this puzzle" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      assert is_nil(Attempts.get_active_attempt(scope, puzzle))
    end

    test "returns nil when attempt is completed" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      solution = String.duplicate("9", 81)
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, _completed} = Attempts.submit_attempt(scope, attempt, solution)

      assert is_nil(Attempts.get_active_attempt(scope, puzzle))
    end

    test "does not leak timing information — return value is not an Attempt struct" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, _attempt} = Attempts.start_attempt(scope, puzzle)

      result = Attempts.get_active_attempt(scope, puzzle)

      # Must be a status atom, not a struct that could expose timing fields
      refute is_struct(result)
      assert is_atom(result)
    end

    test "is scoped to the calling user — other users' attempts are invisible" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      puzzle = easy_puzzle_fixture()

      {:ok, _} = Attempts.start_attempt(scope1, puzzle)
      assert is_nil(Attempts.get_active_attempt(scope2, puzzle))
    end
  end

  # ---------------------------------------------------------------------------
  # list_attempts/2
  # ---------------------------------------------------------------------------
  describe "list_attempts/2" do
    test "returns attempts scoped to the calling user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      puzzle1 = easy_puzzle_fixture()
      puzzle2 = medium_puzzle_fixture()

      {:ok, _} = Attempts.start_attempt(scope1, puzzle1)
      {:ok, _} = Attempts.start_attempt(scope2, puzzle2)

      attempts1 = Attempts.list_attempts(scope1)
      assert length(attempts1) == 1
      assert hd(attempts1).user_id == scope1.user.id
    end

    test "paginates with page and per_page" do
      scope = user_scope_fixture()

      puzzle1 = easy_puzzle_fixture()
      puzzle2 = medium_puzzle_fixture()
      puzzle3 = hard_puzzle_fixture()

      {:ok, _} = Attempts.start_attempt(scope, puzzle1)
      {:ok, _} = Attempts.start_attempt(scope, puzzle2)
      {:ok, _} = Attempts.start_attempt(scope, puzzle3)

      page1 = Attempts.list_attempts(scope, page: 1, per_page: 2)
      assert length(page1) == 2

      page2 = Attempts.list_attempts(scope, page: 2, per_page: 2)
      assert length(page2) == 1
    end

    test "caps per_page at 100 even when a larger value is requested" do
      scope = user_scope_fixture()
      # Insert 101 distinct puzzles and start an attempt for each
      rows =
        for i <- 1..101 do
          clue = String.pad_leading(Integer.to_string(i), 81, "0")
          gc = SudokuRace.Puzzles.givens_count(clue)

          %{
            clues: clue,
            solution: String.duplicate("9", 81),
            givens_count: gc,
            difficulty: SudokuRace.Puzzles.derive_difficulty(gc)
          }
        end

      SudokuRace.Puzzles.import_puzzles(rows)
      puzzles = SudokuRace.Puzzles.list_puzzles(per_page: 101)

      Enum.each(puzzles, fn puzzle ->
        Attempts.start_attempt(scope, puzzle)
      end)

      result = Attempts.list_attempts(scope, per_page: 200)
      assert length(result) == 100
    end

    test "returns empty list when user has no attempts" do
      scope = user_scope_fixture()
      assert Attempts.list_attempts(scope) == []
    end
  end

  # ---------------------------------------------------------------------------
  # get_attempt/2
  # ---------------------------------------------------------------------------
  describe "get_attempt/2" do
    test "returns {:ok, attempt} for an owned attempt" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, fetched} = Attempts.get_attempt(scope, attempt.id)
      assert fetched.id == attempt.id
    end

    test "returns {:error, :not_found} for a non-existent id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_attempt(scope, 999_999_999)
    end

    test "returns {:error, :forbidden} for an attempt owned by another user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope1, puzzle)

      assert {:error, :forbidden} = Attempts.get_attempt(scope2, attempt.id)
    end

    test "accepts a string integer id" do
      scope = user_scope_fixture()
      puzzle = easy_puzzle_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)

      assert {:ok, fetched} = Attempts.get_attempt(scope, Integer.to_string(attempt.id))
      assert fetched.id == attempt.id
    end

    test "returns {:error, :not_found} for non-numeric string id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_attempt(scope, "abc")
    end

    test "returns {:error, :not_found} for empty string id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_attempt(scope, "")
    end

    test "returns {:error, :not_found} for partial-prefix string like '123abc'" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_attempt(scope, "123abc")
    end

    test "returns {:error, :not_found} for out-of-range string id" do
      scope = user_scope_fixture()
      assert {:error, :not_found} = Attempts.get_attempt(scope, "99999999999999")
    end

    test "returns {:error, :not_found} for a non-positive integer id without hitting the DB" do
      scope = user_scope_fixture()
      # 0 and negative integers can never be a valid DB row id — must short-circuit
      assert {:error, :not_found} = Attempts.get_attempt(scope, 0)
      assert {:error, :not_found} = Attempts.get_attempt(scope, -1)
    end

    test "returns {:error, :not_found} for an integer id exceeding PostgreSQL int4 max" do
      scope = user_scope_fixture()
      # int4 max is 2_147_483_647; exceeding it must not raise a DBConnection.EncodeError
      assert {:error, :not_found} = Attempts.get_attempt(scope, 2_147_483_648)
      assert {:error, :not_found} = Attempts.get_attempt(scope, 99_999_999_999_999_999_999)
    end
  end
end
