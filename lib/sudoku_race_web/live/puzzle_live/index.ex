defmodule SudokuRaceWeb.PuzzleLive.Index do
  @moduledoc """
  LiveView for browsing the puzzle pool.

  Allows authenticated users to browse puzzles with difficulty and status
  filtering and pagination. Friend ids are loaded once in mount and cached
  in assigns — no re-query on each filter event.
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Attempts
  alias SudokuRace.Puzzles
  alias SudokuRace.Social

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    friend_ids =
      scope
      |> Social.list_friends(per_page: 100)
      |> Enum.map(& &1.id)

    {:ok,
     socket
     |> assign(:difficulty, nil)
     |> assign(:status, nil)
     |> assign(:hide_mine, false)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign(:friend_ids, friend_ids)
     |> assign(:in_progress_attempts, Attempts.list_in_progress_attempts(scope, per_page: 100))
     |> load_puzzles()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"difficulty" => difficulty}, socket) do
    parsed =
      case difficulty do
        "easy" -> :easy
        "medium" -> :medium
        "hard" -> :hard
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:difficulty, parsed)
     |> assign(:page, 1)
     |> load_puzzles()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    parsed =
      case status do
        "i_solved" -> :i_solved
        "friend_solved" -> :friend_solved
        "unsolved" -> :unsolved
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:status, parsed)
     |> assign(:hide_mine, false)
     |> assign(:page, 1)
     |> load_puzzles()}
  end

  @impl true
  def handle_event("toggle_hide_mine", _params, socket) do
    {:noreply,
     socket
     |> assign(:hide_mine, !socket.assigns.hide_mine)
     |> assign(:page, 1)
     |> load_puzzles()}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, socket.assigns.page + 1)
     |> load_puzzles()}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    new_page = max(1, socket.assigns.page - 1)

    {:noreply,
     socket
     |> assign(:page, new_page)
     |> load_puzzles()}
  end

  defp load_puzzles(socket) do
    %{
      difficulty: difficulty,
      status: status,
      hide_mine: hide_mine,
      page: page,
      per_page: per_page,
      friend_ids: friend_ids,
      current_scope: scope
    } = socket.assigns

    base_opts = [page: page, per_page: per_page]

    opts =
      base_opts
      |> maybe_put_difficulty(difficulty)
      |> maybe_put_status(status, scope.user.id, friend_ids)
      |> maybe_put_hide_mine(hide_mine, scope.user.id)

    count_opts =
      []
      |> maybe_put_difficulty(difficulty)
      |> maybe_put_status(status, scope.user.id, friend_ids)
      |> maybe_put_hide_mine(hide_mine, scope.user.id)

    puzzles = Puzzles.list_puzzles(opts)
    total = Puzzles.count_puzzles(count_opts)

    socket
    |> stream(:puzzles, puzzles, reset: true)
    |> assign(:friend_times, friend_times_lookup(scope, status, friend_ids, puzzles))
    |> assign(:total_puzzles, total)
    |> assign(:has_next, page * per_page < total)
    |> assign(:has_prev, page > 1)
  end

  # Friend solve times are only shown — and only queried — on the friend_solved
  # tab. Batched over the current page's puzzles to avoid an N+1.
  defp friend_times_lookup(scope, :friend_solved, friend_ids, puzzles) do
    puzzle_ids = Enum.map(puzzles, & &1.id)
    Attempts.fastest_friend_times_for_puzzles(scope, friend_ids, puzzle_ids)
  end

  defp friend_times_lookup(_scope, _status, _friend_ids, _puzzles), do: %{}

  defp maybe_put_difficulty(opts, nil), do: opts
  defp maybe_put_difficulty(opts, difficulty), do: Keyword.put(opts, :difficulty, difficulty)

  defp maybe_put_status(opts, nil, _user_id, _friend_ids), do: opts

  defp maybe_put_status(opts, status, user_id, friend_ids) do
    opts
    |> Keyword.put(:status, status)
    |> Keyword.put(:user_id, user_id)
    |> Keyword.put(:friend_ids, friend_ids)
  end

  defp maybe_put_hide_mine(opts, false, _user_id), do: opts

  defp maybe_put_hide_mine(opts, true, user_id) do
    opts
    |> Keyword.put(:hide_mine, true)
    |> Keyword.put_new(:user_id, user_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl px-4 py-8">
        <h1 class="text-2xl font-bold text-gray-900 mb-6">Puzzles</h1>

        <%!-- In-progress attempts pinned at the top --%>
        <section
          :if={@in_progress_attempts != []}
          data-test="in-progress-section"
          aria-labelledby="in-progress-heading"
          class="mb-6"
        >
          <h2 id="in-progress-heading" class="text-lg font-semibold text-gray-900 mb-3">
            In progress
          </h2>
          <ol class="divide-y divide-gray-200 rounded-lg border border-amber-200 bg-amber-50 shadow-sm">
            <li
              :for={attempt <- @in_progress_attempts}
              data-test="in-progress-row"
              class="flex items-center justify-between px-6 py-4"
            >
              <div class="flex items-center gap-4">
                <span
                  data-test="in-progress-label"
                  class="inline-flex items-center rounded-full bg-amber-200 px-2.5 py-0.5 text-xs font-medium text-amber-900"
                >
                  {status_label(attempt.status)}
                </span>
                <span
                  data-test={"difficulty-#{attempt.puzzle.difficulty}"}
                  class={[
                    "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
                    difficulty_badge_class(attempt.puzzle.difficulty)
                  ]}
                >
                  {attempt.puzzle.difficulty}
                </span>
                <span class="text-sm text-gray-500">
                  {attempt.puzzle.givens_count} givens
                </span>
              </div>
              <.link
                navigate={~p"/puzzles/#{attempt.puzzle.id}"}
                class="text-sm font-medium text-amber-700 hover:underline"
                data-test="resume-link"
              >
                Resume
              </.link>
            </li>
          </ol>
        </section>

        <%!-- Difficulty filter controls --%>
        <nav aria-label="Filter puzzles by difficulty" class="mb-4 flex gap-2">
          <button
            type="button"
            data-test="filter-all"
            phx-click="filter"
            phx-value-difficulty="all"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500",
              if(@difficulty == nil,
                do: "bg-indigo-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@difficulty == nil}
          >
            All
          </button>
          <button
            type="button"
            data-test="filter-easy"
            phx-click="filter"
            phx-value-difficulty="easy"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-green-500",
              if(@difficulty == :easy,
                do: "bg-green-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@difficulty == :easy}
          >
            Easy
          </button>
          <button
            type="button"
            data-test="filter-medium"
            phx-click="filter"
            phx-value-difficulty="medium"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-yellow-500",
              if(@difficulty == :medium,
                do: "bg-yellow-500 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@difficulty == :medium}
          >
            Medium
          </button>
          <button
            type="button"
            data-test="filter-hard"
            phx-click="filter"
            phx-value-difficulty="hard"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500",
              if(@difficulty == :hard,
                do: "bg-red-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@difficulty == :hard}
          >
            Hard
          </button>
        </nav>

        <%!-- Status filter controls --%>
        <nav aria-label="Filter puzzles by completion status" class="mb-6 flex gap-2">
          <button
            type="button"
            data-test="filter-status-all"
            phx-click="filter_status"
            phx-value-status="all"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500",
              if(@status == nil,
                do: "bg-indigo-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@status == nil}
            aria-label="Show all puzzles"
          >
            All
          </button>
          <button
            type="button"
            data-test="filter-status-i-solved"
            phx-click="filter_status"
            phx-value-status="i_solved"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-emerald-500",
              if(@status == :i_solved,
                do: "bg-emerald-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@status == :i_solved}
            aria-label="Show puzzles I have solved"
          >
            I Solved
          </button>
          <button
            type="button"
            data-test="filter-status-friend-solved"
            phx-click="filter_status"
            phx-value-status="friend_solved"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500",
              if(@status == :friend_solved,
                do: "bg-blue-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@status == :friend_solved}
            aria-label="Show puzzles a friend solved"
          >
            Friend Solved
          </button>
          <button
            type="button"
            data-test="filter-status-unsolved"
            phx-click="filter_status"
            phx-value-status="unsolved"
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-slate-500",
              if(@status == :unsolved,
                do: "bg-slate-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
            aria-pressed={@status == :unsolved}
            aria-label="Show unsolved puzzles"
          >
            Unsolved
          </button>
        </nav>

        <%!-- Hide-mine toggle — only meaningful on the Friend Solved tab --%>
        <div :if={@status == :friend_solved} class="mb-6">
          <button
            type="button"
            data-test="toggle-hide-mine"
            phx-click="toggle_hide_mine"
            aria-pressed={@hide_mine}
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500",
              if(@hide_mine,
                do: "bg-blue-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
          >
            {if @hide_mine,
              do: "Showing only puzzles I haven't solved",
              else: "Hide puzzles I've solved"}
          </button>
        </div>

        <%!-- Puzzle list --%>
        <%= if @total_puzzles == 0 do %>
          <div class="rounded-lg border border-gray-200 bg-white shadow-sm px-6 py-8 text-center text-gray-500">
            No puzzles found.
          </div>
        <% end %>
        <div
          id="puzzle-list"
          data-test="puzzle-list"
          phx-update="stream"
          class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white shadow-sm"
        >
          <div
            :for={{id, puzzle} <- @streams.puzzles}
            id={id}
            data-test="puzzle-row"
            class="flex items-center justify-between px-6 py-4 hover:bg-gray-50 transition-colors"
          >
            <div class="flex items-center gap-4">
              <span
                data-test={"difficulty-#{puzzle.difficulty}"}
                class={[
                  "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
                  difficulty_badge_class(puzzle.difficulty)
                ]}
              >
                {puzzle.difficulty}
              </span>
              <span class="text-sm text-gray-500">
                {puzzle.givens_count} givens
              </span>
              <span
                :if={@friend_times[puzzle.id]}
                data-test="friend-solve"
                class="text-sm text-blue-700"
              >
                <span data-test="friend-solve-email">
                  {@friend_times[puzzle.id].user.username || @friend_times[puzzle.id].user.email}
                </span>
                solved in
                <span data-test="friend-solve-time" class="font-mono font-medium">
                  {format_elapsed(@friend_times[puzzle.id].elapsed_seconds)}
                </span>
              </span>
            </div>
            <.link
              navigate={~p"/puzzles/#{puzzle.id}"}
              class="text-sm font-medium text-indigo-600 hover:underline"
              data-test="puzzle-play-link"
            >
              Play
            </.link>
          </div>
        </div>

        <%!-- Pagination controls --%>
        <div
          class="mt-6 flex items-center justify-between"
          aria-label="Pagination"
        >
          <span class="text-sm text-gray-600">
            {@total_puzzles} total puzzle{if @total_puzzles != 1, do: "s", else: ""}
          </span>
          <div class="flex gap-2">
            <%= if @has_prev do %>
              <button
                type="button"
                data-test="prev-page"
                phx-click="prev_page"
                class="px-4 py-2 rounded-lg text-sm font-medium bg-gray-100 text-gray-700 hover:bg-gray-200 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                Previous
              </button>
            <% end %>
            <%= if @has_next do %>
              <button
                type="button"
                data-test="next-page"
                phx-click="next_page"
                class="px-4 py-2 rounded-lg text-sm font-medium bg-indigo-600 text-white hover:bg-indigo-700 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                Next
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_label(:in_progress), do: "In progress"
  defp status_label(:paused), do: "Paused"

  defp difficulty_badge_class(:easy), do: "bg-green-100 text-green-800"
  defp difficulty_badge_class(:medium), do: "bg-yellow-100 text-yellow-800"
  defp difficulty_badge_class(:hard), do: "bg-red-100 text-red-800"

  defp format_elapsed(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end
end
