defmodule SudokuRace.PuzzlesTest do
  use SudokuRace.DataCase, async: true

  alias SudokuRace.Puzzles
  alias SudokuRace.Puzzles.Puzzle

  # ---------------------------------------------------------------------------
  # Doctest execution
  # ---------------------------------------------------------------------------
  doctest Puzzles, import: true

  # ---------------------------------------------------------------------------
  # Pure function: givens_count/1
  # ---------------------------------------------------------------------------
  describe "givens_count/1" do
    test "counts non-zero digits in a clue string" do
      clue = String.duplicate("0", 81)
      assert Puzzles.givens_count(clue) == 0
    end

    test "counts correctly when all cells are filled" do
      clue = String.duplicate("1", 81)
      assert Puzzles.givens_count(clue) == 81
    end

    test "counts mixed zeros and digits" do
      # 4 non-zero: positions 0,4,5,7
      clue = "1000110010" <> String.duplicate("0", 71)
      assert Puzzles.givens_count(clue) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # Pure function: derive_difficulty/1
  # ---------------------------------------------------------------------------
  describe "derive_difficulty/1" do
    test "easy for givens >= 35" do
      assert Puzzles.derive_difficulty(35) == :easy
      assert Puzzles.derive_difficulty(36) == :easy
      assert Puzzles.derive_difficulty(37) == :easy
    end

    test "medium for givens == 34" do
      assert Puzzles.derive_difficulty(34) == :medium
    end

    test "hard for givens <= 33" do
      assert Puzzles.derive_difficulty(33) == :hard
      assert Puzzles.derive_difficulty(32) == :hard
      assert Puzzles.derive_difficulty(30) == :hard
    end
  end

  # ---------------------------------------------------------------------------
  # Changeset / schema validation
  # ---------------------------------------------------------------------------
  describe "Puzzle changeset" do
    @valid_clue String.duplicate("0", 40) <> String.duplicate("1", 41)
    @valid_solution String.duplicate("9", 81)

    test "valid attributes produce a valid changeset" do
      gc = Puzzles.givens_count(@valid_clue)
      diff = Puzzles.derive_difficulty(gc)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: @valid_clue,
          solution: @valid_solution,
          givens_count: gc,
          difficulty: diff
        })

      assert changeset.valid?
    end

    test "invalid when clues is not 81 chars" do
      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: "12345",
          solution: @valid_solution,
          givens_count: 5,
          difficulty: :hard
        })

      refute changeset.valid?
      assert %{clues: [_ | _]} = errors_on(changeset)
    end

    test "invalid when solution is not 81 chars" do
      gc = Puzzles.givens_count(@valid_clue)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: @valid_clue,
          solution: "short",
          givens_count: gc,
          difficulty: :easy
        })

      refute changeset.valid?
      assert %{solution: [_ | _]} = errors_on(changeset)
    end

    test "invalid when clues contains non-digit characters" do
      bad_clue = String.duplicate("x", 81)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: bad_clue,
          solution: @valid_solution,
          givens_count: 0,
          difficulty: :hard
        })

      refute changeset.valid?
      assert %{clues: [_ | _]} = errors_on(changeset)
    end

    test "invalid when solution contains non-digit characters" do
      bad_solution = String.duplicate("x", 81)
      gc = Puzzles.givens_count(@valid_clue)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: @valid_clue,
          solution: bad_solution,
          givens_count: gc,
          difficulty: :hard
        })

      refute changeset.valid?
      assert %{solution: [_ | _]} = errors_on(changeset)
    end

    test "invalid when givens_count is inconsistent with clues" do
      gc = Puzzles.givens_count(@valid_clue)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: @valid_clue,
          solution: @valid_solution,
          givens_count: gc + 5,
          difficulty: :hard
        })

      refute changeset.valid?
      assert %{givens_count: [_ | _]} = errors_on(changeset)
    end

    test "invalid when difficulty is not in enum" do
      gc = Puzzles.givens_count(@valid_clue)

      changeset =
        Puzzle.changeset(%Puzzle{}, %{
          clues: @valid_clue,
          solution: @valid_solution,
          givens_count: gc,
          difficulty: :legendary
        })

      refute changeset.valid?
      assert %{difficulty: [_ | _]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # import_puzzles/1 — bulk insert, idempotency
  # ---------------------------------------------------------------------------
  describe "import_puzzles/1" do
    @clue_a String.duplicate("0", 47) <> String.duplicate("1", 34)
    @clue_b String.duplicate("0", 46) <> String.duplicate("2", 35)

    defp puzzle_row(clue) do
      gc = Puzzles.givens_count(clue)

      %{
        clues: clue,
        solution: String.duplicate("9", 81),
        givens_count: gc,
        difficulty: Puzzles.derive_difficulty(gc)
      }
    end

    test "inserts new puzzles and returns {:ok, count} inserted" do
      rows = [puzzle_row(@clue_a), puzzle_row(@clue_b)]
      assert {:ok, 2} = Puzzles.import_puzzles(rows)
    end

    test "re-running with same clues is a no-op (idempotent)" do
      rows = [puzzle_row(@clue_a)]
      assert {:ok, 1} = Puzzles.import_puzzles(rows)
      assert {:ok, 0} = Puzzles.import_puzzles(rows)
    end

    test "only inserts new rows when mixed with existing ones" do
      rows_first = [puzzle_row(@clue_a)]
      rows_second = [puzzle_row(@clue_a), puzzle_row(@clue_b)]
      assert {:ok, 1} = Puzzles.import_puzzles(rows_first)
      assert {:ok, 1} = Puzzles.import_puzzles(rows_second)
    end
  end

  # ---------------------------------------------------------------------------
  # list_puzzles/1 — pagination and difficulty filter
  # ---------------------------------------------------------------------------
  describe "list_puzzles/1" do
    setup do
      # Insert known puzzles across difficulties
      easy_clue = String.duplicate("1", 35) <> String.duplicate("0", 46)
      medium_clue = String.duplicate("1", 34) <> String.duplicate("0", 47)
      hard_clue = String.duplicate("1", 33) <> String.duplicate("0", 48)

      rows = [
        %{
          clues: easy_clue,
          solution: String.duplicate("9", 81),
          givens_count: 35,
          difficulty: :easy
        },
        %{
          clues: medium_clue,
          solution: String.duplicate("9", 81),
          givens_count: 34,
          difficulty: :medium
        },
        %{
          clues: hard_clue,
          solution: String.duplicate("9", 81),
          givens_count: 33,
          difficulty: :hard
        }
      ]

      Puzzles.import_puzzles(rows)
      :ok
    end

    test "returns all puzzles by default" do
      puzzles = Puzzles.list_puzzles()
      assert length(puzzles) == 3
    end

    test "filters by difficulty :easy" do
      puzzles = Puzzles.list_puzzles(difficulty: :easy)
      assert length(puzzles) == 1
      assert hd(puzzles).difficulty == :easy
    end

    test "filters by difficulty :medium" do
      puzzles = Puzzles.list_puzzles(difficulty: :medium)
      assert length(puzzles) == 1
      assert hd(puzzles).difficulty == :medium
    end

    test "filters by difficulty :hard" do
      puzzles = Puzzles.list_puzzles(difficulty: :hard)
      assert length(puzzles) == 1
      assert hd(puzzles).difficulty == :hard
    end

    test "paginates with page and per_page" do
      puzzles = Puzzles.list_puzzles(page: 1, per_page: 2)
      assert length(puzzles) == 2

      puzzles_p2 = Puzzles.list_puzzles(page: 2, per_page: 2)
      assert length(puzzles_p2) == 1
    end

    test "caps per_page at 100 even when a larger value is requested" do
      # Insert 101 distinct puzzles to guarantee the pool exceeds the cap
      extra_rows =
        for i <- 1..101 do
          # Pad with "0" so each string is exactly 81 digits; the numeric value
          # of i determines how many non-zero digits appear (1–3), keeping
          # givens_count consistent with the actual clue content.
          clue = String.pad_leading(Integer.to_string(i), 81, "0")
          gc = Puzzles.givens_count(clue)

          %{
            clues: clue,
            solution: String.duplicate("9", 81),
            givens_count: gc,
            difficulty: Puzzles.derive_difficulty(gc)
          }
        end

      Puzzles.import_puzzles(extra_rows)

      # Requesting 200 per page must be silently capped to 100
      puzzles = Puzzles.list_puzzles(per_page: 200)
      assert length(puzzles) == 100
    end
  end

  # ---------------------------------------------------------------------------
  # count_puzzles/1
  # ---------------------------------------------------------------------------
  describe "count_puzzles/1" do
    setup do
      easy_clue = String.duplicate("2", 35) <> String.duplicate("0", 46)
      hard_clue = String.duplicate("2", 33) <> String.duplicate("0", 48)

      Puzzles.import_puzzles([
        %{
          clues: easy_clue,
          solution: String.duplicate("9", 81),
          givens_count: 35,
          difficulty: :easy
        },
        %{
          clues: hard_clue,
          solution: String.duplicate("9", 81),
          givens_count: 33,
          difficulty: :hard
        }
      ])

      :ok
    end

    test "counts all puzzles with no filter" do
      assert Puzzles.count_puzzles() == 2
    end

    test "counts by difficulty filter" do
      assert Puzzles.count_puzzles(difficulty: :easy) == 1
      assert Puzzles.count_puzzles(difficulty: :hard) == 1
      assert Puzzles.count_puzzles(difficulty: :medium) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # get_puzzle/1
  # ---------------------------------------------------------------------------
  describe "get_puzzle/1" do
    test "returns {:ok, puzzle} for existing id" do
      clue = String.duplicate("3", 35) <> String.duplicate("0", 46)

      Puzzles.import_puzzles([
        %{
          clues: clue,
          solution: String.duplicate("9", 81),
          givens_count: 35,
          difficulty: :easy
        }
      ])

      [puzzle] = Puzzles.list_puzzles()
      assert {:ok, fetched} = Puzzles.get_puzzle(puzzle.id)
      assert fetched.id == puzzle.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Puzzles.get_puzzle(999_999_999)
    end

    test "accepts a string-integer id and returns {:ok, puzzle} for existing id" do
      clue = String.duplicate("4", 35) <> String.duplicate("0", 46)

      Puzzles.import_puzzles([
        %{
          clues: clue,
          solution: String.duplicate("9", 81),
          givens_count: 35,
          difficulty: :easy
        }
      ])

      [puzzle] = Puzzles.list_puzzles()
      assert {:ok, fetched} = Puzzles.get_puzzle(Integer.to_string(puzzle.id))
      assert fetched.id == puzzle.id
    end

    test "returns {:error, :not_found} for string-integer id of non-existent puzzle" do
      assert {:error, :not_found} = Puzzles.get_puzzle("999999999")
    end

    test "returns {:error, :not_found} for non-numeric string" do
      assert {:error, :not_found} = Puzzles.get_puzzle("abc")
    end

    test "returns {:error, :not_found} for empty string" do
      assert {:error, :not_found} = Puzzles.get_puzzle("")
    end

    test "returns {:error, :not_found} for partial-prefix string like '123abc'" do
      assert {:error, :not_found} = Puzzles.get_puzzle("123abc")
    end

    test "returns {:error, :not_found} for out-of-range (int4 overflow) string id" do
      assert {:error, :not_found} = Puzzles.get_puzzle("99999999999999")
    end
  end

  # ---------------------------------------------------------------------------
  # get_playable_puzzle/1
  # ---------------------------------------------------------------------------
  describe "get_playable_puzzle/1" do
    test "returns {:ok, map} with safe fields for an existing puzzle" do
      clue = String.duplicate("5", 35) <> String.duplicate("0", 46)
      solution = String.duplicate("9", 81)

      Puzzles.import_puzzles([
        %{
          clues: clue,
          solution: solution,
          givens_count: 35,
          difficulty: :easy
        }
      ])

      [puzzle] = Puzzles.list_puzzles(difficulty: :easy)
      assert {:ok, playable} = Puzzles.get_playable_puzzle(puzzle.id)

      # Must have safe fields
      assert playable.id == puzzle.id
      assert playable.clues == clue
      assert playable.difficulty == :easy
      assert playable.givens_count == 35

      # SECURITY: must NOT include the solution
      refute Map.has_key?(playable, :solution)
      # Must be a plain map, not a %Puzzle{} struct (which carries solution)
      refute is_struct(playable)
    end

    test "returns {:error, :not_found} for a non-existent id" do
      assert {:error, :not_found} = Puzzles.get_playable_puzzle(999_999_999)
    end

    test "returns {:error, :not_found} for a string id of a non-existent puzzle" do
      assert {:error, :not_found} = Puzzles.get_playable_puzzle("999999999")
    end

    test "accepts a string integer id and returns {:ok, map} for existing puzzle" do
      clue = String.duplicate("6", 35) <> String.duplicate("0", 46)

      Puzzles.import_puzzles([
        %{
          clues: clue,
          solution: String.duplicate("9", 81),
          givens_count: 35,
          difficulty: :easy
        }
      ])

      [puzzle] = Puzzles.list_puzzles(difficulty: :easy)
      assert {:ok, playable} = Puzzles.get_playable_puzzle(Integer.to_string(puzzle.id))
      assert playable.id == puzzle.id
    end

    test "returns {:error, :not_found} for non-numeric string" do
      assert {:error, :not_found} = Puzzles.get_playable_puzzle("not-a-number")
    end
  end
end
