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
  # friend_times_for_puzzle/3
  # ---------------------------------------------------------------------------
  describe "friend_times_for_puzzle/3" do
    import SudokuRace.SocialFixtures, only: [accepted_friendship_fixture: 2]

    # Helper: start + submit attempt for scope on puzzle, returns completed attempt.
    defp complete(scope, puzzle) do
      {:ok, attempt} = Attempts.start_attempt(scope, puzzle)
      {:ok, completed} = Attempts.submit_attempt(scope, attempt, String.duplicate("9", 81))
      completed
    end

    setup do
      me = user_fixture()
      my_scope = user_scope_fixture(me)

      friend_a = user_fixture()
      friend_b = user_fixture()
      friend_a_scope = user_scope_fixture(friend_a)
      friend_b_scope = user_scope_fixture(friend_b)

      stranger = user_fixture()
      stranger_scope = user_scope_fixture(stranger)

      accepted_friendship_fixture(me, friend_a)
      accepted_friendship_fixture(me, friend_b)

      puzzle = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})

      {:ok,
       me: me,
       my_scope: my_scope,
       friend_a: friend_a,
       friend_a_scope: friend_a_scope,
       friend_b: friend_b,
       friend_b_scope: friend_b_scope,
       stranger: stranger,
       stranger_scope: stranger_scope,
       puzzle: puzzle,
       friend_ids: [friend_a.id, friend_b.id]}
    end

    test "returns [] when current user has NOT completed the puzzle (privacy gate)", ctx do
      # I have not completed — friend has
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "returns [] when current user is in_progress (privacy gate)", ctx do
      {:ok, _} = Attempts.start_attempt(ctx.my_scope, ctx.puzzle)
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "returns [] when current user is paused (privacy gate)", ctx do
      {:ok, attempt} = Attempts.start_attempt(ctx.my_scope, ctx.puzzle)
      {:ok, _} = Attempts.pause_attempt(ctx.my_scope, attempt)
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "returns [] when current user completed but no friends completed", ctx do
      complete(ctx.my_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "returns friend's entry when both current user and friend completed", ctx do
      complete(ctx.my_scope, ctx.puzzle)
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert length(result) == 1
      [entry] = result
      assert entry.user.id == ctx.friend_a.id
      assert is_integer(entry.elapsed_seconds)
      assert %DateTime{} = entry.completed_at
    end

    test "excludes friends who are in_progress but not completed", ctx do
      complete(ctx.my_scope, ctx.puzzle)
      # friend_a only started, not completed
      {:ok, _} = Attempts.start_attempt(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "excludes strangers even if they completed", ctx do
      complete(ctx.my_scope, ctx.puzzle)
      complete(ctx.stranger_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert result == []
    end

    test "includes multiple friends who completed, ordered by elapsed_seconds ASC", ctx do
      complete(ctx.my_scope, ctx.puzzle)

      # friend_a completes first (should have lower elapsed_seconds in practice,
      # but elapsed_seconds is computed server-side at submission time; we can't
      # control the exact order reliably in tests). Instead we verify both appear
      # and that the list is sorted.
      complete(ctx.friend_a_scope, ctx.puzzle)
      complete(ctx.friend_b_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      assert length(result) == 2

      user_ids = Enum.map(result, & &1.user.id)
      assert ctx.friend_a.id in user_ids
      assert ctx.friend_b.id in user_ids

      # Verify ascending order by elapsed_seconds
      elapsed = Enum.map(result, & &1.elapsed_seconds)
      assert elapsed == Enum.sort(elapsed)
    end

    test "returns [] when friend_ids is empty (even if I completed)", ctx do
      complete(ctx.my_scope, ctx.puzzle)
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, [])
      assert result == []
    end

    test "returns [] for a bad string puzzle_id (never raises)", ctx do
      result = Attempts.friend_times_for_puzzle(ctx.my_scope, "not-an-id", ctx.friend_ids)
      assert result == []
    end

    test "returns [] for an out-of-range puzzle_id string", ctx do
      result = Attempts.friend_times_for_puzzle(ctx.my_scope, "99999999999999", ctx.friend_ids)
      assert result == []
    end

    test "returns [] for an integer puzzle_id that doesn't exist", ctx do
      complete(ctx.my_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, 999_999_999, ctx.friend_ids)
      assert result == []
    end

    test "user field carries email for display when no other name field exists", ctx do
      complete(ctx.my_scope, ctx.puzzle)
      complete(ctx.friend_a_scope, ctx.puzzle)

      result = Attempts.friend_times_for_puzzle(ctx.my_scope, ctx.puzzle.id, ctx.friend_ids)
      [entry] = result
      assert is_binary(entry.user.email)
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

  # ---------------------------------------------------------------------------
  # friend_leaderboard/3
  # ---------------------------------------------------------------------------
  describe "friend_leaderboard/3" do
    setup do
      me = user_fixture()
      my_scope = user_scope_fixture(me)

      friend = user_fixture()
      friend_scope = user_scope_fixture(friend)

      stranger = user_fixture()
      stranger_scope = user_scope_fixture(stranger)

      puzzle_a = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})
      puzzle_b = medium_puzzle_fixture(%{solution: String.duplicate("9", 81)})

      {:ok,
       my_scope: my_scope,
       friend: friend,
       friend_scope: friend_scope,
       stranger_scope: stranger_scope,
       puzzle_a: puzzle_a,
       puzzle_b: puzzle_b,
       friend_ids: [friend.id]}
    end

    test "returns [] when friend_ids is empty", ctx do
      complete(ctx.friend_scope, ctx.puzzle_a)
      assert Attempts.friend_leaderboard(ctx.my_scope, []) == []
    end

    test "returns a friend's completed solves with puzzle and user", ctx do
      complete(ctx.friend_scope, ctx.puzzle_a)

      [entry] = Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids)
      assert entry.user.id == ctx.friend.id
      assert entry.puzzle.id == ctx.puzzle_a.id
      assert is_integer(entry.elapsed_seconds)
      assert %DateTime{} = entry.completed_at
    end

    test "includes every puzzle a friend solved", ctx do
      complete(ctx.friend_scope, ctx.puzzle_a)
      complete(ctx.friend_scope, ctx.puzzle_b)

      result = Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids)
      puzzle_ids = Enum.map(result, & &1.puzzle.id)
      assert length(result) == 2
      assert ctx.puzzle_a.id in puzzle_ids
      assert ctx.puzzle_b.id in puzzle_ids
    end

    test "excludes strangers' solves even though they are not in friend_ids", ctx do
      complete(ctx.stranger_scope, ctx.puzzle_a)

      assert Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids) == []
    end

    test "excludes in-progress (not completed) attempts", ctx do
      {:ok, _} = Attempts.start_attempt(ctx.friend_scope, ctx.puzzle_a)

      assert Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids) == []
    end

    test "orders by elapsed_seconds ascending (fastest first)", ctx do
      complete(ctx.friend_scope, ctx.puzzle_a)
      complete(ctx.friend_scope, ctx.puzzle_b)

      result = Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids)
      elapsed = Enum.map(result, & &1.elapsed_seconds)
      assert elapsed == Enum.sort(elapsed)
    end

    test "paginates results", ctx do
      complete(ctx.friend_scope, ctx.puzzle_a)
      complete(ctx.friend_scope, ctx.puzzle_b)

      page1 = Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids, page: 1, per_page: 1)
      page2 = Attempts.friend_leaderboard(ctx.my_scope, ctx.friend_ids, page: 2, per_page: 1)

      assert length(page1) == 1
      assert length(page2) == 1
      refute hd(page1).puzzle.id == hd(page2).puzzle.id
    end
  end

  # ---------------------------------------------------------------------------
  # fastest_friend_times_for_puzzles/3
  # ---------------------------------------------------------------------------
  describe "fastest_friend_times_for_puzzles/3" do
    setup do
      me = user_fixture()
      my_scope = user_scope_fixture(me)
      friend = user_fixture()
      friend_scope = user_scope_fixture(friend)
      stranger_scope = user_scope_fixture(user_fixture())
      puzzle = easy_puzzle_fixture(%{solution: String.duplicate("9", 81)})

      {:ok,
       my_scope: my_scope,
       friend: friend,
       friend_scope: friend_scope,
       stranger_scope: stranger_scope,
       puzzle: puzzle,
       friend_ids: [friend.id]}
    end

    test "returns %{} when friend_ids is empty", ctx do
      complete(ctx.friend_scope, ctx.puzzle)
      assert Attempts.fastest_friend_times_for_puzzles(ctx.my_scope, [], [ctx.puzzle.id]) == %{}
    end

    test "returns %{} when puzzle_ids is empty", ctx do
      complete(ctx.friend_scope, ctx.puzzle)
      assert Attempts.fastest_friend_times_for_puzzles(ctx.my_scope, ctx.friend_ids, []) == %{}
    end

    test "returns the friend's solve keyed by puzzle id", ctx do
      complete(ctx.friend_scope, ctx.puzzle)

      result =
        Attempts.fastest_friend_times_for_puzzles(ctx.my_scope, ctx.friend_ids, [ctx.puzzle.id])

      entry = result[ctx.puzzle.id]
      assert entry.user.id == ctx.friend.id
      assert is_integer(entry.elapsed_seconds)
      assert %DateTime{} = entry.completed_at
    end

    test "has no privacy gate — surfaces friend time even if I have not solved", ctx do
      # The current user never completes the puzzle, yet the friend's time shows.
      complete(ctx.friend_scope, ctx.puzzle)

      result =
        Attempts.fastest_friend_times_for_puzzles(ctx.my_scope, ctx.friend_ids, [ctx.puzzle.id])

      assert Map.has_key?(result, ctx.puzzle.id)
    end

    test "excludes solves by users not in friend_ids", ctx do
      complete(ctx.stranger_scope, ctx.puzzle)

      result =
        Attempts.fastest_friend_times_for_puzzles(ctx.my_scope, ctx.friend_ids, [ctx.puzzle.id])

      assert result == %{}
    end

    test "returns the FASTEST friend when two friends solved the same puzzle", ctx do
      slow = user_fixture()
      fast = user_fixture()
      now = ~U[2024-01-01 00:00:00.000000Z]

      # Insert completed attempts directly so elapsed_seconds is controlled —
      # submit_attempt computes it server-side and would be ~0 for both.
      SudokuRace.Repo.insert!(%Attempt{
        user_id: slow.id,
        puzzle_id: ctx.puzzle.id,
        status: :completed,
        started_at: now,
        completed_at: now,
        elapsed_seconds: 300
      })

      SudokuRace.Repo.insert!(%Attempt{
        user_id: fast.id,
        puzzle_id: ctx.puzzle.id,
        status: :completed,
        started_at: now,
        completed_at: now,
        elapsed_seconds: 42
      })

      result =
        Attempts.fastest_friend_times_for_puzzles(
          ctx.my_scope,
          [slow.id, fast.id],
          [ctx.puzzle.id]
        )

      entry = result[ctx.puzzle.id]
      assert entry.user.id == fast.id
      assert entry.elapsed_seconds == 42
    end

    test "omits puzzles with no friend solve", ctx do
      other = medium_puzzle_fixture(%{solution: String.duplicate("9", 81)})
      complete(ctx.friend_scope, ctx.puzzle)

      result =
        Attempts.fastest_friend_times_for_puzzles(
          ctx.my_scope,
          ctx.friend_ids,
          [ctx.puzzle.id, other.id]
        )

      assert Map.has_key?(result, ctx.puzzle.id)
      refute Map.has_key?(result, other.id)
    end
  end

  # ---------------------------------------------------------------------------
  # save_entries/3
  # ---------------------------------------------------------------------------
  describe "save_entries/3" do
    setup do
      scope = user_scope_fixture()
      {:ok, attempt} = Attempts.start_attempt(scope, easy_puzzle_fixture())
      {:ok, scope: scope, attempt: attempt}
    end

    test "persists the board for the owner while in progress", ctx do
      board = String.duplicate("1", 40) <> String.duplicate("0", 41)
      assert {:ok, saved} = Attempts.save_entries(ctx.scope, ctx.attempt, board)
      assert saved.entries == board

      assert Attempts.get_attempt(ctx.scope, ctx.attempt.id) |> elem(1) |> Map.get(:entries) ==
               board
    end

    test "returns :forbidden for a non-owner", ctx do
      other = user_scope_fixture()

      assert {:error, :forbidden} =
               Attempts.save_entries(other, ctx.attempt, String.duplicate("0", 81))
    end

    test "returns :not_in_progress when the attempt is paused", ctx do
      {:ok, paused} = Attempts.pause_attempt(ctx.scope, ctx.attempt)

      assert {:error, :not_in_progress} =
               Attempts.save_entries(ctx.scope, paused, String.duplicate("0", 81))
    end

    test "returns :not_found for an unknown id", ctx do
      assert {:error, :not_found} =
               Attempts.save_entries(ctx.scope, 999_999_999, String.duplicate("0", 81))
    end
  end

  # ---------------------------------------------------------------------------
  # list_in_progress_attempts/2
  # ---------------------------------------------------------------------------
  describe "list_in_progress_attempts/2" do
    setup do
      %{scope: user_scope_fixture(user_fixture())}
    end

    test "returns in_progress and paused attempts (puzzle preloaded), excludes completed", ctx do
      sol = String.duplicate("9", 81)
      ip = easy_puzzle_fixture(%{solution: sol})
      paused = medium_puzzle_fixture(%{solution: sol})
      done = hard_puzzle_fixture(%{solution: sol})

      {:ok, _} = Attempts.start_attempt(ctx.scope, ip)
      {:ok, p} = Attempts.start_attempt(ctx.scope, paused)
      {:ok, _} = Attempts.pause_attempt(ctx.scope, p)
      complete(ctx.scope, done)

      results = Attempts.list_in_progress_attempts(ctx.scope)
      puzzle_ids = Enum.map(results, & &1.puzzle.id)

      assert ip.id in puzzle_ids
      assert paused.id in puzzle_ids
      refute done.id in puzzle_ids
      assert Enum.sort(Enum.map(results, & &1.status)) == [:in_progress, :paused]
      assert %SudokuRace.Puzzles.Puzzle{} = hd(results).puzzle
    end

    test "is scoped to the user", ctx do
      other = user_scope_fixture(user_fixture())

      {:ok, _} =
        Attempts.start_attempt(other, easy_puzzle_fixture(%{solution: String.duplicate("9", 81)}))

      assert Attempts.list_in_progress_attempts(ctx.scope) == []
    end
  end
end
