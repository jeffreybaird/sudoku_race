defmodule SudokuRace.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed, e.g. in a Docker container.

  Usage (from within the release):
      bin/sudoku_race eval "SudokuRace.Release.migrate()"
      bin/sudoku_race eval "SudokuRace.Release.rollback(SudokuRace.Repo, 20230101000000)"
      bin/sudoku_race eval "SudokuRace.Release.seed_puzzles()"
  """

  @app :sudoku_race

  # Target count per difficulty band for seeding.
  # Change this to seed a larger pool; re-running is safe (idempotent).
  @puzzles_per_band 334

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seeds the puzzle pool from `data/sudoku.csv`.

  Streams the CSV without loading it all into memory. Samples up to
  `@puzzles_per_band` puzzles per difficulty band (~#{@puzzles_per_band * 3}
  total) and inserts them via the `Puzzles` context. Re-running is safe:
  existing puzzles are not duplicated (`on_conflict: :nothing`).

  Reports how many rows were inserted.
  """
  def seed_puzzles do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(SudokuRace.Repo, fn _repo -> do_seed_puzzles() end)
  end

  @doc """
  Seeds puzzles from the given CSV path.
  Called directly by `priv/repo/seeds.exs` and by `seed_puzzles/0`.
  """
  @spec seed_puzzles_from_csv(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def seed_puzzles_from_csv(csv_path) do
    alias SudokuRace.Puzzles

    batch_size = 200
    target = @puzzles_per_band

    {:ok, counters} = Agent.start_link(fn -> %{easy: 0, medium: 0, hard: 0} end)

    total_inserted =
      csv_path
      |> File.stream!()
      |> Stream.drop(1)
      |> Stream.map(&parse_csv_line/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.transform(nil, &sample_row(&1, &2, counters, target))
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(0, fn batch, acc -> acc + Puzzles.import_puzzles(batch) end)

    Agent.stop(counters)

    total_rows = target * 3
    {total_inserted, max(0, total_rows - total_inserted)}
  end

  defp sample_row(row, acc, counters, target) do
    counts = Agent.get(counters, & &1)
    diff = row.difficulty

    cond do
      counts[diff] < target ->
        Agent.update(counters, fn c -> Map.update!(c, diff, &(&1 + 1)) end)
        {[row], acc}

      all_bands_full?(counts, target) ->
        {:halt, acc}

      true ->
        {[], acc}
    end
  end

  defp all_bands_full?(counts, target) do
    counts.easy >= target and counts.medium >= target and counts.hard >= target
  end

  defp do_seed_puzzles do
    csv_path = Application.app_dir(:sudoku_race, "priv/data/sudoku.csv")
    alt_path = Path.join(File.cwd!(), "data/sudoku.csv")

    path =
      cond do
        File.exists?(csv_path) -> csv_path
        File.exists?(alt_path) -> alt_path
        true -> raise "sudoku.csv not found at #{csv_path} or #{alt_path}"
      end

    {inserted, _} = seed_puzzles_from_csv(path)
    IO.puts("Seeded puzzles: #{inserted} inserted")
  end

  defp parse_csv_line(line) do
    alias SudokuRace.Puzzles

    line = String.trim(line)

    case String.split(line, ",", parts: 2) do
      [quiz, solution]
      when byte_size(quiz) == 81 and byte_size(solution) == 81 ->
        if String.match?(quiz, ~r/\A[0-9]{81}\z/) and
             String.match?(solution, ~r/\A[0-9]{81}\z/) do
          gc = Puzzles.givens_count(quiz)

          %{
            clues: quiz,
            solution: solution,
            givens_count: gc,
            difficulty: Puzzles.derive_difficulty(gc)
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
