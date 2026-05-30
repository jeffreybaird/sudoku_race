defmodule SudokuRace.Attempts do
  @moduledoc """
  Context for puzzle attempts — timing, solution validation, lifecycle.

  ## Server-authoritative timing

  All timing is server-side. Clients never supply durations. The
  `elapsed_seconds` column is set once, on completion, by the server.
  """

  import Ecto.Query

  alias SudokuRace.Accounts.Scope
  alias SudokuRace.Accounts.User
  alias SudokuRace.Attempts.Attempt
  alias SudokuRace.Puzzles.Puzzle
  alias SudokuRace.Repo

  @max_per_page 100
  @default_per_page 20

  # PostgreSQL int4 max value.
  @int4_max 2_147_483_647

  # ---------------------------------------------------------------------------
  # Pure functions
  # ---------------------------------------------------------------------------

  @doc """
  Computes elapsed seconds for an attempt at a given point in time.

  This is a pure function — `now` is injected by the caller so it is
  deterministic and doctestable. Never calls `DateTime.utc_now/0` internally.

  Returns:
  - `:completed` attempts → the frozen `elapsed_seconds` column value.
  - `:paused` attempts → `accumulated_seconds` (no running segment).
  - `:in_progress` attempts → `accumulated_seconds` + seconds since `segment_started_at`.

  ## Examples

      iex> attempt = %SudokuRace.Attempts.Attempt{
      ...>   status: :in_progress,
      ...>   accumulated_seconds: 10,
      ...>   segment_started_at: ~U[2024-01-01 00:00:00Z],
      ...>   elapsed_seconds: nil
      ...> }
      iex> SudokuRace.Attempts.elapsed_seconds(attempt, ~U[2024-01-01 00:01:00Z])
      70

      iex> paused = %SudokuRace.Attempts.Attempt{
      ...>   status: :paused,
      ...>   accumulated_seconds: 42,
      ...>   segment_started_at: nil,
      ...>   elapsed_seconds: nil
      ...> }
      iex> SudokuRace.Attempts.elapsed_seconds(paused, ~U[2024-01-01 00:00:00Z])
      42

      iex> completed = %SudokuRace.Attempts.Attempt{
      ...>   status: :completed,
      ...>   accumulated_seconds: 100,
      ...>   segment_started_at: nil,
      ...>   elapsed_seconds: 150
      ...> }
      iex> SudokuRace.Attempts.elapsed_seconds(completed, ~U[2024-01-01 00:00:00Z])
      150

  """
  @spec elapsed_seconds(Attempt.t(), DateTime.t()) :: non_neg_integer()
  def elapsed_seconds(%Attempt{status: :completed, elapsed_seconds: secs}, _now), do: secs

  def elapsed_seconds(%Attempt{status: :paused, accumulated_seconds: acc}, _now), do: acc

  def elapsed_seconds(%Attempt{status: :in_progress} = attempt, now) do
    segment_secs = DateTime.diff(now, attempt.segment_started_at, :second)
    attempt.accumulated_seconds + segment_secs
  end

  # ---------------------------------------------------------------------------
  # start_attempt/2
  # ---------------------------------------------------------------------------

  @doc """
  Starts a new attempt for the scoped user on the given puzzle.

  Returns `{:ok, attempt}` on success.
  Returns `{:error, :not_found}` if the puzzle does not exist in the database.
  Returns `{:error, :already_attempted}` if the user already has an attempt for
  this puzzle (mapped from the `(user_id, puzzle_id)` unique constraint —
  race-safe, no pre-check SELECT).
  """
  @spec start_attempt(Scope.t(), Puzzle.t()) ::
          {:ok, Attempt.t()}
          | {:error, :not_found}
          | {:error, :already_attempted}
          | {:error, :validation, Ecto.Changeset.t()}
  def start_attempt(%Scope{} = scope, %Puzzle{id: puzzle_id}) when not is_nil(puzzle_id) do
    case Repo.get(Puzzle, puzzle_id) do
      nil -> {:error, :not_found}
      _puzzle -> insert_new_attempt(scope.user.id, puzzle_id)
    end
  end

  # ---------------------------------------------------------------------------
  # pause_attempt/2
  # ---------------------------------------------------------------------------

  @doc """
  Pauses an in-progress attempt, accumulating the current running segment into
  `accumulated_seconds`. Sets `segment_started_at` to nil and status to `:paused`.

  The `elapsed_seconds` column is NOT touched — it is only written on completion.

  Returns `{:ok, attempt}` on success.
  Returns `{:error, :not_in_progress}` if the attempt is not currently `:in_progress`.
  Returns `{:error, :forbidden}` if the scope user does not own the attempt.
  Returns `{:error, :not_found}` if the attempt does not exist.
  """
  @spec pause_attempt(Scope.t(), Attempt.t() | integer() | String.t()) ::
          {:ok, Attempt.t()}
          | {:error, :not_in_progress}
          | {:error, :forbidden}
          | {:error, :not_found}
  def pause_attempt(%Scope{} = scope, attempt_or_id) do
    with {:ok, attempt} <- load_and_authorize(scope, attempt_or_id),
         :ok <- require_status(attempt, :in_progress, :not_in_progress) do
      now = DateTime.utc_now()
      segment_secs = DateTime.diff(now, attempt.segment_started_at, :second)
      new_accumulated = attempt.accumulated_seconds + segment_secs

      attempt
      |> Attempt.update_changeset(%{
        status: :paused,
        accumulated_seconds: new_accumulated,
        segment_started_at: nil
      })
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # resume_attempt/2
  # ---------------------------------------------------------------------------

  @doc """
  Resumes a paused attempt by setting `segment_started_at` to the current time
  and status back to `:in_progress`.

  Returns `{:ok, attempt}` on success.
  Returns `{:error, :not_paused}` if the attempt is not currently `:paused`.
  Returns `{:error, :forbidden}` if the scope user does not own the attempt.
  Returns `{:error, :not_found}` if the attempt does not exist.
  """
  @spec resume_attempt(Scope.t(), Attempt.t() | integer() | String.t()) ::
          {:ok, Attempt.t()}
          | {:error, :not_paused}
          | {:error, :forbidden}
          | {:error, :not_found}
  def resume_attempt(%Scope{} = scope, attempt_or_id) do
    with {:ok, attempt} <- load_and_authorize(scope, attempt_or_id),
         :ok <- require_status(attempt, :paused, :not_paused) do
      now = DateTime.utc_now()

      attempt
      |> Attempt.update_changeset(%{
        status: :in_progress,
        segment_started_at: now
      })
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # submit_attempt/3
  # ---------------------------------------------------------------------------

  @doc """
  Submits a solution for an in-progress attempt.

  Validation order:
  1. Load attempt and verify ownership (`:forbidden` / `:not_found`).
  2. Check status: paused → `:not_in_progress`; completed → `:already_completed`.
  3. Validate `submitted_solution` format (81-digit string) → `{:error, :validation, changeset}`.
  4. Compare with stored puzzle solution → `:incorrect_solution` if wrong (attempt unchanged).
  5. On match: compute authoritative `elapsed_seconds` server-side, write completion fields.

  Client-supplied durations are ignored entirely — the function signature accepts
  only `scope`, `attempt_or_id`, and `submitted_solution`.

  Returns `{:ok, completed_attempt}` on success.
  """
  @spec submit_attempt(Scope.t(), Attempt.t() | integer() | String.t(), String.t()) ::
          {:ok, Attempt.t()}
          | {:error, :not_in_progress}
          | {:error, :already_completed}
          | {:error, :incorrect_solution}
          | {:error, :validation, Ecto.Changeset.t()}
          | {:error, :forbidden}
          | {:error, :not_found}
  def submit_attempt(%Scope{} = scope, attempt_or_id, submitted_solution) do
    with {:ok, attempt} <- load_and_authorize(scope, attempt_or_id),
         :ok <- check_submit_status(attempt),
         :ok <- validate_solution_format(submitted_solution),
         {:ok, puzzle} <- load_puzzle_for_attempt(attempt),
         :ok <- check_solution_correct(submitted_solution, puzzle.solution) do
      now = DateTime.utc_now()
      final_elapsed = elapsed_seconds(attempt, now)

      attempt
      |> Attempt.update_changeset(%{
        status: :completed,
        elapsed_seconds: final_elapsed,
        completed_at: now,
        segment_started_at: nil
      })
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # get_owner_attempt_for_puzzle/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the scoped user's attempt (any status) for the given puzzle.

  Unlike `get_active_attempt/2`, this function returns the full `%Attempt{}`
  struct for the owner's own attempt — covering `:in_progress`, `:paused`, and
  `:completed` statuses. Timing fields are safe to expose to the solver because
  they are their own attempt data.

  `puzzle_id` accepts an integer or string-integer id.

  Returns `{:ok, attempt}` when the user has an attempt for this puzzle.
  Returns `{:error, :not_found}` when no attempt exists.
  """
  @spec get_owner_attempt_for_puzzle(Scope.t(), integer() | String.t()) ::
          {:ok, Attempt.t()} | {:error, :not_found}
  def get_owner_attempt_for_puzzle(%Scope{} = scope, puzzle_id) when is_integer(puzzle_id) do
    result =
      Attempt
      |> where([a], a.user_id == ^scope.user.id)
      |> where([a], a.puzzle_id == ^puzzle_id)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt}
    end
  end

  def get_owner_attempt_for_puzzle(%Scope{} = scope, puzzle_id) when is_binary(puzzle_id) do
    case Integer.parse(puzzle_id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        get_owner_attempt_for_puzzle(scope, int_id)

      _ ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # get_active_attempt/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the status atom (`:in_progress` or `:paused`) for the scoped user's
  active attempt on the given puzzle, or `nil` if no active attempt exists.

  An attempt is "active" when its status is `:in_progress` or `:paused`.
  Completed attempts are not returned — use `list_attempts/2` or `get_attempt/2`
  to access those.

  ## Return shape

  Intentionally returns only the status atom — NOT an `%Attempt{}` struct.
  This prevents callers from accidentally reading timing fields
  (`accumulated_seconds`, `segment_started_at`, `elapsed_seconds`) and
  exposing a running clock to the UI before completion.
  """
  @spec get_active_attempt(Scope.t(), Puzzle.t()) :: :in_progress | :paused | nil
  def get_active_attempt(%Scope{} = scope, %Puzzle{id: puzzle_id}) do
    Attempt
    |> where([a], a.user_id == ^scope.user.id)
    |> where([a], a.puzzle_id == ^puzzle_id)
    |> where([a], a.status in [:in_progress, :paused])
    |> select([a], a.status)
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # friend_times_for_puzzle/3
  # ---------------------------------------------------------------------------

  @doc """
  Returns completed attempt times for accepted friends on a given puzzle,
  but ONLY when the current user (scope) has also completed the puzzle.

  Privacy gate: if the scoped user has not completed this puzzle, returns `[]`
  immediately. This check is part of the single database query via a correlated
  EXISTS subquery — no separate SELECT is issued first.

  Each entry in the returned list is a map:

      %{
        user: %User{},
        elapsed_seconds: integer(),
        completed_at: DateTime.t()
      }

  Results are ordered by `elapsed_seconds` ascending (fastest first).

  `puzzle_id` accepts an integer or string-integer. Invalid strings,
  out-of-range values, and unknown ids return `[]` without raising.
  Returns `[]` immediately when `friend_ids` is empty.
  """
  @spec friend_times_for_puzzle(Scope.t(), integer() | String.t(), [integer()]) :: [map()]
  def friend_times_for_puzzle(%Scope{}, _puzzle_id, []), do: []

  def friend_times_for_puzzle(%Scope{} = scope, puzzle_id, friend_ids)
      when is_binary(puzzle_id) do
    case Integer.parse(puzzle_id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        friend_times_for_puzzle(scope, int_id, friend_ids)

      _ ->
        []
    end
  end

  def friend_times_for_puzzle(%Scope{} = scope, puzzle_id, friend_ids)
      when is_integer(puzzle_id) and puzzle_id > 0 and puzzle_id <= @int4_max do
    user_id = scope.user.id

    Attempt
    |> join(:inner, [a], u in User, on: u.id == a.user_id)
    |> where([a], a.puzzle_id == ^puzzle_id)
    |> where([a], a.user_id in ^friend_ids)
    |> where([a], a.status == :completed)
    |> where(
      [a],
      exists(
        from(self_a in Attempt,
          where: self_a.puzzle_id == ^puzzle_id,
          where: self_a.user_id == ^user_id,
          where: self_a.status == :completed,
          select: 1
        )
      )
    )
    |> order_by([a], asc: a.elapsed_seconds)
    |> select([a, u], %{user: u, elapsed_seconds: a.elapsed_seconds, completed_at: a.completed_at})
    |> Repo.all()
  end

  def friend_times_for_puzzle(%Scope{}, _puzzle_id, _friend_ids), do: []

  # ---------------------------------------------------------------------------
  # friend_leaderboard/3
  # ---------------------------------------------------------------------------

  @doc """
  Returns a friends-only leaderboard: every puzzle a friend has completed,
  fastest solve first.

  This is NOT a public leaderboard. Only completed attempts whose `user_id` is
  in `friend_ids` are included — a non-friend's data is never exposed. Callers
  pass the scoped user's accepted-friend ids (both directions).

  Each entry is a map:

      %{
        user: %User{},
        puzzle: %Puzzle{},
        elapsed_seconds: integer(),
        completed_at: DateTime.t()
      }

  Results are ordered by `elapsed_seconds` ascending (fastest first), then by
  `completed_at` ascending as a stable tiebreak.

  Returns `[]` immediately when `friend_ids` is empty.

  ## Options

  - `:page`     — 1-based page number (default: 1)
  - `:per_page` — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  """
  @spec friend_leaderboard(Scope.t(), [integer()], keyword()) :: [map()]
  def friend_leaderboard(scope, friend_ids, opts \\ [])

  def friend_leaderboard(%Scope{}, [], _opts), do: []

  def friend_leaderboard(%Scope{}, friend_ids, opts) when is_list(friend_ids) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> min(@max_per_page)
    offset = (page - 1) * per_page

    Attempt
    |> join(:inner, [a], u in User, on: u.id == a.user_id)
    |> join(:inner, [a], p in Puzzle, on: p.id == a.puzzle_id)
    |> where([a], a.user_id in ^friend_ids)
    |> where([a], a.status == :completed)
    |> order_by([a], asc: a.elapsed_seconds, asc: a.completed_at)
    |> limit(^per_page)
    |> offset(^offset)
    |> select([a, u, p], %{
      user: u,
      puzzle: p,
      elapsed_seconds: a.elapsed_seconds,
      completed_at: a.completed_at
    })
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # fastest_friend_times_for_puzzles/3
  # ---------------------------------------------------------------------------

  @doc """
  Returns the fastest friend solve for each of the given puzzles, keyed by
  puzzle id.

  Unlike `friend_times_for_puzzle/3`, there is NO privacy gate: this surfaces a
  friend's time even on puzzles the current user has not solved — it backs the
  "Friend Solved" puzzle list, whose whole purpose is showing friends' solves.
  Only `:completed` attempts by users in `friend_ids` are considered.

  The result is a map; each value is:

      %{user: %User{}, elapsed_seconds: integer(), completed_at: DateTime.t()}

  Puzzles with no friend solve are simply absent from the map. Returns `%{}`
  when `friend_ids` or `puzzle_ids` is empty. Batched over all puzzle ids in a
  single query (no N+1).
  """
  @spec fastest_friend_times_for_puzzles(Scope.t(), [integer()], [integer()]) :: %{
          integer() => map()
        }
  def fastest_friend_times_for_puzzles(%Scope{}, [], _puzzle_ids), do: %{}
  def fastest_friend_times_for_puzzles(%Scope{}, _friend_ids, []), do: %{}

  def fastest_friend_times_for_puzzles(%Scope{}, friend_ids, puzzle_ids)
      when is_list(friend_ids) and is_list(puzzle_ids) do
    Attempt
    |> join(:inner, [a], u in User, on: u.id == a.user_id)
    |> where([a], a.user_id in ^friend_ids)
    |> where([a], a.puzzle_id in ^puzzle_ids)
    |> where([a], a.status == :completed)
    # DISTINCT ON (puzzle_id) keeps the first row per puzzle after ordering, so
    # the lowest elapsed_seconds wins — and we keep the solver's identity too.
    |> distinct([a], a.puzzle_id)
    |> order_by([a], asc: a.puzzle_id, asc: a.elapsed_seconds)
    |> select(
      [a, u],
      {a.puzzle_id, %{user: u, elapsed_seconds: a.elapsed_seconds, completed_at: a.completed_at}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # list_attempts/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of attempts for the scoped user.

  ## Options

  - `:page`     — 1-based page number (default: 1)
  - `:per_page` — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  """
  @spec list_attempts(Scope.t(), keyword()) :: [Attempt.t()]
  def list_attempts(%Scope{} = scope, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> min(@max_per_page)
    offset = (page - 1) * per_page

    Attempt
    |> where([a], a.user_id == ^scope.user.id)
    |> order_by([a], desc: a.id)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # get_attempt/2
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a single attempt by id.

  Accepts either an integer or a string representation of an integer.
  Strings are parsed strictly — partial matches like `"123abc"` are rejected.
  Out-of-range values and unknown ids return `{:error, :not_found}` without raising.

  Returns `{:ok, attempt}` if the attempt exists and belongs to the scoped user.
  Returns `{:error, :forbidden}` if the attempt exists but belongs to another user.
  Returns `{:error, :not_found}` otherwise.
  """
  @spec get_attempt(Scope.t(), integer() | String.t()) ::
          {:ok, Attempt.t()} | {:error, :not_found} | {:error, :forbidden}
  def get_attempt(%Scope{} = scope, id) when is_integer(id) and id > 0 and id <= @int4_max do
    case Repo.get(Attempt, id) do
      nil ->
        {:error, :not_found}

      attempt ->
        if attempt.user_id == scope.user.id do
          {:ok, attempt}
        else
          {:error, :forbidden}
        end
    end
  end

  def get_attempt(%Scope{}, id) when is_integer(id), do: {:error, :not_found}

  def get_attempt(%Scope{} = scope, id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        get_attempt(scope, int_id)

      _ ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp insert_new_attempt(user_id, puzzle_id) do
    now = DateTime.utc_now()

    %Attempt{user_id: user_id, puzzle_id: puzzle_id}
    |> Attempt.create_changeset(%{
      status: :in_progress,
      started_at: now,
      segment_started_at: now,
      accumulated_seconds: 0
    })
    |> Repo.insert()
    |> map_unique_constraint_to_already_attempted()
  end

  defp map_unique_constraint_to_already_attempted({:ok, attempt}), do: {:ok, attempt}

  defp map_unique_constraint_to_already_attempted({:error, %Ecto.Changeset{} = changeset}) do
    if unique_constraint_violated?(changeset.errors, :user_id) do
      {:error, :already_attempted}
    else
      # Defensive fallback — unreachable by construction: all fields in
      # create_changeset are set internally (user_id, puzzle_id, status,
      # started_at, accumulated_seconds) and there are no other validations.
      # Retained to satisfy CLAUDE.md §2 (no bare {:error, changeset}) and to
      # prevent a silent swallow if an unexpected validation is ever added.
      {:error, :validation, changeset}
    end
  end

  defp unique_constraint_violated?(errors, field) do
    case Keyword.get(errors, field) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  defp load_and_authorize(scope, %Attempt{} = attempt) do
    if attempt.user_id == scope.user.id do
      {:ok, attempt}
    else
      {:error, :forbidden}
    end
  end

  defp load_and_authorize(scope, id) when is_integer(id) or is_binary(id) do
    get_attempt(scope, id)
  end

  defp require_status(%Attempt{status: status}, required, _error_tag)
       when status == required,
       do: :ok

  defp require_status(_attempt, _required, error_tag), do: {:error, error_tag}

  defp check_submit_status(%Attempt{status: :in_progress}), do: :ok
  defp check_submit_status(%Attempt{status: :paused}), do: {:error, :not_in_progress}
  defp check_submit_status(%Attempt{status: :completed}), do: {:error, :already_completed}

  defp validate_solution_format(solution) when is_binary(solution) do
    changeset =
      {%{}, %{submitted_solution: :string}}
      |> Ecto.Changeset.cast(%{submitted_solution: solution}, [:submitted_solution])
      |> Ecto.Changeset.validate_format(:submitted_solution, ~r/\A[1-9]{81}\z/,
        message: "must be exactly 81 digits (1-9)"
      )

    if changeset.valid? do
      :ok
    else
      {:error, :validation, changeset}
    end
  end

  defp load_puzzle_for_attempt(%Attempt{puzzle_id: puzzle_id}) do
    case Repo.get(Puzzle, puzzle_id) do
      nil -> {:error, :not_found}
      puzzle -> {:ok, puzzle}
    end
  end

  defp check_solution_correct(submitted, stored) when submitted == stored, do: :ok
  defp check_solution_correct(_submitted, _stored), do: {:error, :incorrect_solution}
end
