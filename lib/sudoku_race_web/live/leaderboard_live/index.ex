defmodule SudokuRaceWeb.LeaderboardLive.Index do
  @moduledoc """
  Friends-only leaderboard.

  Lists the puzzles the current user's friends have solved, fastest solve
  first. Scoped strictly to accepted friendships (both directions) — never a
  public leaderboard. Friend ids are loaded once in mount and cached in
  assigns; pagination re-queries the leaderboard only.
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Attempts
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
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> assign(:friend_ids, friend_ids)
     |> load_entries()}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, socket.assigns.page + 1)
     |> load_entries()}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, max(1, socket.assigns.page - 1))
     |> load_entries()}
  end

  defp load_entries(socket) do
    %{
      page: page,
      per_page: per_page,
      friend_ids: friend_ids,
      current_scope: scope
    } = socket.assigns

    # Fetch one extra row to detect a next page without a count query — avoids
    # showing a "Next" button that leads to an empty page at exact multiples.
    fetched = Attempts.friend_leaderboard(scope, friend_ids, page: page, per_page: per_page + 1)
    entries = Enum.take(fetched, per_page)

    socket
    |> assign(:entries, entries)
    |> assign(:rank_offset, (page - 1) * per_page)
    |> assign(:has_next, length(fetched) > per_page)
    |> assign(:has_prev, page > 1)
  end

  defp format_elapsed(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl px-4 py-8">
        <h1 class="text-2xl font-bold text-gray-900 mb-2">Friends leaderboard</h1>
        <p class="text-sm text-gray-500 mb-6">
          Puzzles your friends have solved, fastest first.
        </p>

        <%= if @friend_ids == [] do %>
          <div
            data-test="no-friends"
            class="rounded-lg border border-gray-200 bg-white shadow-sm px-6 py-8 text-center text-gray-500"
          >
            No friends yet.
            <.link navigate={~p"/friends"} class="text-indigo-600 hover:underline">
              Add a friend
            </.link>
            to see their solves here.
          </div>
        <% else %>
          <%= if @entries == [] do %>
            <div
              data-test="no-entries"
              class="rounded-lg border border-gray-200 bg-white shadow-sm px-6 py-8 text-center text-gray-500"
            >
              None of your friends have solved a puzzle yet.
            </div>
          <% end %>

          <ol
            :if={@entries != []}
            data-test="leaderboard"
            class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white shadow-sm"
          >
            <li
              :for={{entry, idx} <- Enum.with_index(@entries)}
              data-test="leaderboard-row"
              class="flex items-center gap-4 px-6 py-4"
            >
              <span
                data-test="leaderboard-rank"
                class="w-8 shrink-0 text-sm font-semibold text-gray-400"
                aria-hidden="true"
              >
                #{@rank_offset + idx + 1}
              </span>
              <span class="flex-1 min-w-0">
                <span class="block text-sm font-medium text-gray-900" data-test="leaderboard-user">
                  {entry.user.username || entry.user.email}
                </span>
                <.link
                  navigate={~p"/puzzles/#{entry.puzzle.id}"}
                  class="block text-xs text-indigo-600 hover:underline"
                  data-test="leaderboard-puzzle-link"
                >
                  {entry.puzzle.difficulty} · {entry.puzzle.givens_count} givens
                </.link>
              </span>
              <span
                data-test="leaderboard-time"
                class="shrink-0 font-mono text-sm font-semibold text-gray-900"
              >
                {format_elapsed(entry.elapsed_seconds)}
              </span>
            </li>
          </ol>

          <div class="mt-6 flex items-center justify-end gap-2" aria-label="Pagination">
            <%= if @has_prev do %>
              <button
                type="button"
                data-test="prev-page"
                phx-click="prev_page"
                class="min-h-[44px] rounded-lg bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-200 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                Previous
              </button>
            <% end %>
            <%= if @has_next do %>
              <button
                type="button"
                data-test="next-page"
                phx-click="next_page"
                class="min-h-[44px] rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                Next
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
