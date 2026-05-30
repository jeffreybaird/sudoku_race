defmodule SudokuRace.Puzzles do
  @moduledoc """
  Context for the Sudoku puzzle pool.

  ## Difficulty derivation policy

  Difficulty is derived from the number of non-zero ("given") cells in the
  81-character clue string. The public dataset (1 M puzzles) shows a tight
  givens distribution of 30–36:

      givens   ~%
        <=33   ~34%   → :hard
          34   ~45%   → :medium
        >=35   ~21%   → :easy

  Thresholds chosen to produce a non-degenerate three-band split across the
  real data. Higher givens = more information = easier puzzle.

  ## Cross-context EXISTS subqueries

  `list_puzzles/1` and `count_puzzles/1` accept a `:status` filter that
  correlates against the `attempts` table (owned by the `Attempts` context).
  This is an intentional cross-context query — the app is small enough that
  a separate read-model or denormalized table would be over-engineering.
  The query never modifies `attempts` and uses only a correlated EXISTS
  subquery, keeping the dependency read-only and unidirectional.
  """

  import Ecto.Query

  alias SudokuRace.Puzzles.Puzzle
  alias SudokuRace.Repo

  @max_per_page 100
  @default_per_page 20

  # ---------------------------------------------------------------------------
  # Pure functions
  # ---------------------------------------------------------------------------

  @doc """
  Counts the number of non-zero characters in an 81-character clue string.
  Zero characters (`"0"`) represent blank cells; any other digit is a given.

  ## Examples

      iex> SudokuRace.Puzzles.givens_count(String.duplicate("0", 81))
      0

      iex> SudokuRace.Puzzles.givens_count(String.duplicate("5", 81))
      81

      iex> SudokuRace.Puzzles.givens_count("1" <> String.duplicate("0", 80))
      1

  """
  @spec givens_count(String.t()) :: non_neg_integer()
  def givens_count(clue) when is_binary(clue) do
    clue
    |> String.graphemes()
    |> Enum.count(&(&1 != "0"))
  end

  @doc """
  Maps a givens count to a difficulty atom using the dataset-derived thresholds:

  - `:easy`   — 35 or more givens  (~21% of the dataset)
  - `:medium` — exactly 34 givens  (~45% of the dataset)
  - `:hard`   — 33 or fewer givens (~34% of the dataset)

  ## Examples

      iex> SudokuRace.Puzzles.derive_difficulty(35)
      :easy

      iex> SudokuRace.Puzzles.derive_difficulty(36)
      :easy

      iex> SudokuRace.Puzzles.derive_difficulty(34)
      :medium

      iex> SudokuRace.Puzzles.derive_difficulty(33)
      :hard

      iex> SudokuRace.Puzzles.derive_difficulty(30)
      :hard

  """
  @spec derive_difficulty(non_neg_integer()) :: :easy | :medium | :hard
  def derive_difficulty(givens) when givens >= 35, do: :easy
  def derive_difficulty(34), do: :medium
  def derive_difficulty(_givens), do: :hard

  # ---------------------------------------------------------------------------
  # DB functions
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of puzzles, optionally filtered by difficulty and/or
  friend-relative status.

  ## Options

  - `:page`       — 1-based page number (default: 1)
  - `:per_page`   — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  - `:difficulty` — one of `:easy`, `:medium`, `:hard`; omit for all difficulties
  - `:status`     — one of `:i_solved`, `:friend_solved`, `:unsolved`; omit for no filter.
                    Requires `:user_id` and `:friend_ids` when provided.
  - `:user_id`    — integer user id of the current user (required when `:status` is set)
  - `:friend_ids` — list of integer user ids of accepted friends (required when `:status` is set)
  - `:hide_mine`  — when `true`, excludes puzzles the current user has already
                    completed. Independent of `:status`; requires `:user_id`.

  ### Status semantics

  - `:i_solved`      — current user has a `:completed` attempt on this puzzle
  - `:friend_solved` — at least one friend has a `:completed` attempt (regardless of
                       whether the current user has also solved it). Pair with
                       `:hide_mine` to drop puzzles you've already solved.
  - `:unsolved`      — no `:completed` attempt from current user or any friend
                       (`:in_progress`/`:paused` attempts do not count as solved)

  """
  @spec list_puzzles(keyword()) :: [Puzzle.t()]
  def list_puzzles(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> min(@max_per_page)
    difficulty = Keyword.get(opts, :difficulty)
    status = Keyword.get(opts, :status)
    user_id = Keyword.get(opts, :user_id)
    friend_ids = Keyword.get(opts, :friend_ids, [])
    hide_mine = Keyword.get(opts, :hide_mine, false)
    offset = (page - 1) * per_page

    from(p in Puzzle, as: :puzzle)
    |> apply_difficulty_filter(difficulty)
    |> apply_status_filter(status, user_id, friend_ids)
    |> apply_hide_mine(hide_mine, user_id)
    |> order_by([p], asc: p.id)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Counts puzzles, optionally filtered by difficulty and/or friend-relative status.

  ## Options

  - `:difficulty` — one of `:easy`, `:medium`, `:hard`; omit for all difficulties
  - `:status`     — one of `:i_solved`, `:friend_solved`, `:unsolved`; omit for no filter.
                    Requires `:user_id` and `:friend_ids` when provided.
  - `:user_id`    — integer user id of the current user (required when `:status` is set)
  - `:friend_ids` — list of integer user ids of accepted friends (required when `:status` is set)
  - `:hide_mine`  — when `true`, excludes puzzles the current user has already
                    completed. Independent of `:status`; requires `:user_id`.

  """
  @spec count_puzzles(keyword()) :: non_neg_integer()
  def count_puzzles(opts \\ []) do
    difficulty = Keyword.get(opts, :difficulty)
    status = Keyword.get(opts, :status)
    user_id = Keyword.get(opts, :user_id)
    friend_ids = Keyword.get(opts, :friend_ids, [])
    hide_mine = Keyword.get(opts, :hide_mine, false)

    from(p in Puzzle, as: :puzzle)
    |> apply_difficulty_filter(difficulty)
    |> apply_status_filter(status, user_id, friend_ids)
    |> apply_hide_mine(hide_mine, user_id)
    |> Repo.aggregate(:count, :id)
  end

  # PostgreSQL int4 max value.
  @int4_max 2_147_483_647

  @doc """
  Fetches a single puzzle by id.

  Accepts either an integer or a string representation of an integer.
  Strings are parsed strictly — partial matches like `"123abc"` are rejected.
  Out-of-range values (negative, zero, or exceeding PostgreSQL int4 max) and
  unknown ids return `{:error, :not_found}` without raising.

  Returns `{:ok, puzzle}` on success or `{:error, :not_found}` otherwise.
  """
  @spec get_puzzle(integer() | String.t()) :: {:ok, Puzzle.t()} | {:error, :not_found}
  def get_puzzle(id) when is_integer(id) do
    case Repo.get(Puzzle, id) do
      nil -> {:error, :not_found}
      puzzle -> {:ok, puzzle}
    end
  end

  def get_puzzle(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        get_puzzle(int_id)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetches a puzzle's safe (non-solution) fields for the play UI.

  Returns `{:ok, map}` with only the fields needed to render the grid:
  `:id`, `:clues`, `:difficulty`, `:givens_count`. The `:solution` field is
  deliberately excluded via a `select` so it never enters LiveView assigns or
  the websocket payload.

  Accepts either an integer or a string representation of an integer.
  Strings are parsed strictly — partial matches like `"123abc"` are rejected.
  Out-of-range values and unknown ids return `{:error, :not_found}`.
  """
  @spec get_playable_puzzle(integer() | String.t()) ::
          {:ok, %{id: integer(), clues: String.t(), difficulty: atom(), givens_count: integer()}}
          | {:error, :not_found}
  def get_playable_puzzle(id) when is_integer(id) do
    result =
      Puzzle
      |> where([p], p.id == ^id)
      |> select([p], %{
        id: p.id,
        clues: p.clues,
        difficulty: p.difficulty,
        givens_count: p.givens_count
      })
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      playable -> {:ok, playable}
    end
  end

  def get_playable_puzzle(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        get_playable_puzzle(int_id)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Bulk-inserts puzzles from a list of attribute maps.

  Uses `on_conflict: :nothing` with `conflict_target: :clues` so that
  re-running the seed never duplicates existing puzzles.

  Returns `{:ok, count}` where `count` is the number of rows actually inserted
  (skipped rows are not counted).
  Each map must include: `:clues`, `:solution`, `:givens_count`, `:difficulty`.
  """
  @spec import_puzzles([map()]) :: {:ok, non_neg_integer()}
  def import_puzzles(rows) when is_list(rows) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _} =
      Repo.insert_all(Puzzle, entries,
        on_conflict: :nothing,
        conflict_target: :clues
      )

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_difficulty_filter(query, nil), do: query

  defp apply_difficulty_filter(query, difficulty) do
    where(query, [p], p.difficulty == ^difficulty)
  end

  # Status filter — shared predicate helper used by both list_puzzles and
  # count_puzzles so counts never diverge from listed results.
  #
  # :i_solved      — EXISTS a completed attempt by the current user
  # :friend_solved — EXISTS a completed attempt by a friend (independent of
  #                  whether the current user has also solved it). Use the
  #                  :hide_mine filter to drop the user's own solves.
  # :unsolved      — NOT EXISTS any completed attempt by current user or friends
  # nil            — no additional filter

  defp apply_status_filter(query, nil, _user_id, _friend_ids), do: query

  defp apply_status_filter(query, :i_solved, user_id, _friend_ids) do
    where(
      query,
      [p],
      exists(
        from(a in "attempts",
          where: a.puzzle_id == parent_as(:puzzle).id,
          where: a.user_id == ^user_id,
          where: a.status == ^"completed",
          select: 1
        )
      )
    )
  end

  defp apply_status_filter(query, :friend_solved, _user_id, []), do: where(query, false)

  defp apply_status_filter(query, :friend_solved, _user_id, friend_ids) do
    where(
      query,
      [p],
      exists(
        from(a in "attempts",
          where: a.puzzle_id == parent_as(:puzzle).id,
          where: a.user_id in ^friend_ids,
          where: a.status == ^"completed",
          select: 1
        )
      )
    )
  end

  defp apply_status_filter(query, :unsolved, user_id, friend_ids) do
    solved_user_ids = [user_id | friend_ids]

    where(
      query,
      [p],
      not exists(
        from(a in "attempts",
          where: a.puzzle_id == parent_as(:puzzle).id,
          where: a.user_id in ^solved_user_ids,
          where: a.status == ^"completed",
          select: 1
        )
      )
    )
  end

  # Excludes puzzles the current user has already completed. Independent of the
  # status filter so it can compose with :friend_solved ("friends' puzzles I
  # haven't done yet"). A no-op when disabled or when user_id is missing.
  defp apply_hide_mine(query, true, user_id) when is_integer(user_id) do
    where(
      query,
      [p],
      not exists(
        from(a in "attempts",
          where: a.puzzle_id == parent_as(:puzzle).id,
          where: a.user_id == ^user_id,
          where: a.status == ^"completed",
          select: 1
        )
      )
    )
  end

  defp apply_hide_mine(query, _hide_mine, _user_id), do: query
end
