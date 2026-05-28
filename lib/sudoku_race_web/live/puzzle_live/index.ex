defmodule SudokuRaceWeb.PuzzleLive.Index do
  @moduledoc """
  LiveView for browsing the puzzle pool.

  Allows authenticated users to browse puzzles with difficulty filtering
  and pagination. Difficulty is the only filter available at this stage.
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Puzzles

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:difficulty, nil)
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
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
    %{difficulty: difficulty, page: page, per_page: per_page} = socket.assigns

    opts =
      [page: page, per_page: per_page]
      |> maybe_put_difficulty(difficulty)

    puzzles = Puzzles.list_puzzles(opts)
    total = Puzzles.count_puzzles(maybe_put_difficulty([], difficulty))

    socket
    |> stream(:puzzles, puzzles, reset: true)
    |> assign(:total_puzzles, total)
    |> assign(:has_next, page * per_page < total)
    |> assign(:has_prev, page > 1)
  end

  defp maybe_put_difficulty(opts, nil), do: opts
  defp maybe_put_difficulty(opts, difficulty), do: Keyword.put(opts, :difficulty, difficulty)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl px-4 py-8">
        <h1 class="text-2xl font-bold text-gray-900 mb-6">Puzzles</h1>

        <%!-- Difficulty filter controls --%>
        <nav aria-label="Filter puzzles by difficulty" class="mb-6 flex gap-2">
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
            </div>
            <.link
              navigate={~p"/puzzles/#{puzzle.id}"}
              class="font-mono text-xs text-indigo-600 hover:underline truncate max-w-xs"
              data-test="puzzle-play-link"
            >
              {String.slice(puzzle.clues, 0, 20)}…
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

  defp difficulty_badge_class(:easy), do: "bg-green-100 text-green-800"
  defp difficulty_badge_class(:medium), do: "bg-yellow-100 text-yellow-800"
  defp difficulty_badge_class(:hard), do: "bg-red-100 text-red-800"
end
