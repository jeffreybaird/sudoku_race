defmodule SudokuRaceWeb.PuzzleLive.Show do
  @moduledoc """
  LiveView for the puzzle solve UI.

  ## Security

  The puzzle `solution` field NEVER enters LiveView assigns or the websocket.
  `Puzzles.get_playable_puzzle/1` returns only `id`, `clues`, `difficulty`, and
  `givens_count` via a `select` — the `%Puzzle{}` struct (which carries `solution`)
  is never assigned. Solution comparison happens exclusively inside
  `Attempts.submit_attempt/3` server-side.

  ## State machine

  The view branches on the current user's attempt status for this puzzle:

  - `nil` / no attempt → `:start` — start page, grid NOT rendered, no clue digits in DOM.
  - `:in_progress` → `:playing` — ARIA grid revealed, pause/submit buttons.
  - `:paused` → `:paused` — grid NOT rendered (conditional, not CSS hide), resume button.
  - `:completed` → `:completed` — server-recorded `elapsed_seconds` shown, no grid.

  ## Input mode

  Session-only input mode toggle (`:pointer` or `:touch`). NOT persisted to the
  user profile or DB — an intentional scope constraint for this step. A thin
  InputModeDetect JS hook may push `input_mode:detect` to let the server detect
  a coarse pointer automatically.

  ## JS hooks

  Three thin hooks (no game logic):
  - `.GridKeyboard` — routes grid input as `cell_focus`/`cell_entry` events:
    physical keyboard (arrows, digits, backspace), and on touch a cell tap that
    focuses the hidden `#mobile-entry` input to summon the native numeric
    keyboard, routing the typed digit to the tapped cell.
  - `.Timer` — renders the ticking elapsed display using `accumulated_seconds` +
    `segment_started_at` data attributes pushed via `push_event/3` on every
    transition to `:in_progress` (both mount and resume).
  - `.InputModeDetect` — detects touch vs. pointer and pushes `input_mode:detect`.

  Hooks run only in the browser (Wallaby). Server-side handlers are tested via
  `render_hook/3` in `show_test.exs`.
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Attempts
  alias SudokuRace.Puzzles
  alias SudokuRace.Social

  @impl true
  def mount(%{"id" => puzzle_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Puzzles.get_playable_puzzle(puzzle_id) do
      {:ok, puzzle} ->
        friend_ids =
          scope
          |> Social.list_friends(per_page: 100)
          |> Enum.map(& &1.id)

        socket =
          socket
          |> assign(:puzzle, puzzle)
          |> assign(:status_message, nil)
          |> assign(:input_mode, :pointer)
          |> assign(:friend_ids, friend_ids)
          |> load_attempt_state(scope, puzzle.id, puzzle.clues)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "No puzzle found with that ID.")
         |> push_navigate(to: ~p"/puzzles")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Start attempt
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("start", _params, socket) do
    scope = socket.assigns.current_scope
    puzzle = socket.assigns.puzzle
    puzzle_struct = %SudokuRace.Puzzles.Puzzle{id: puzzle.id}

    case Attempts.start_attempt(scope, puzzle_struct) do
      {:ok, attempt} ->
        socket =
          socket
          |> assign(:attempt, attempt)
          |> assign(:view_state, :playing)
          |> assign(:grid, build_grid(puzzle.clues))
          |> assign(:focused_cell, first_editable_index(puzzle.clues))
          |> assign(:status_message, nil)
          |> push_timer_seed(attempt)

        {:noreply, socket}

      {:error, :already_attempted} ->
        # Reload the actual attempt state from DB and re-sync
        socket = load_attempt_state(socket, scope, puzzle.id, puzzle.clues)
        {:noreply, assign(socket, :status_message, nil)}

      {:error, :not_found} ->
        {:noreply, assign(socket, :status_message, "Puzzle not found.")}

      {:error, :validation, _changeset} ->
        {:noreply, assign(socket, :status_message, "Unable to start attempt.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Pause attempt
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pause", _params, socket) do
    scope = socket.assigns.current_scope
    attempt = socket.assigns.attempt

    case Attempts.pause_attempt(scope, attempt) do
      {:ok, paused} ->
        socket =
          socket
          |> assign(:attempt, paused)
          |> assign(:view_state, :paused)
          |> assign(:status_message, "Paused")

        {:noreply, socket}

      {:error, :not_in_progress} ->
        socket =
          load_attempt_state(socket, scope, socket.assigns.puzzle.id, socket.assigns.puzzle.clues)

        {:noreply, assign(socket, :status_message, "Already paused or completed.")}

      {:error, error_tag} when error_tag in [:forbidden, :not_found] ->
        {:noreply, assign(socket, :status_message, "Unable to pause. Please refresh.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Resume attempt
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("resume", _params, socket) do
    scope = socket.assigns.current_scope
    attempt = socket.assigns.attempt

    case Attempts.resume_attempt(scope, attempt) do
      {:ok, resumed} ->
        socket =
          socket
          |> assign(:attempt, resumed)
          |> assign(:view_state, :playing)
          |> assign(:focused_cell, first_editable_index(socket.assigns.puzzle.clues))
          |> assign(:status_message, "Resumed")
          |> push_timer_seed(resumed)

        {:noreply, socket}

      {:error, :not_paused} ->
        socket =
          load_attempt_state(socket, scope, socket.assigns.puzzle.id, socket.assigns.puzzle.clues)

        {:noreply, assign(socket, :status_message, "Already in progress or completed.")}

      {:error, error_tag} when error_tag in [:forbidden, :not_found] ->
        {:noreply, assign(socket, :status_message, "Unable to resume. Please refresh.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Cell entry (routed from GridKeyboard hook)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("cell_entry", %{"position" => pos, "value" => value}, socket)
      when is_integer(pos) do
    grid = socket.assigns.grid
    clues = socket.assigns.puzzle.clues
    clue_at_pos = String.at(clues, pos)

    # Only allow entry on non-given cells
    if clue_at_pos == "0" do
      new_grid = List.replace_at(grid, pos, value)
      socket = assign(socket, :grid, new_grid)

      # Persist the server-derived board so progress survives reconnect/deploy.
      socket =
        case Attempts.save_entries(
               socket.assigns.current_scope,
               socket.assigns.attempt,
               Enum.join(new_grid)
             ) do
          {:ok, attempt} -> assign(socket, :attempt, attempt)
          {:error, _reason} -> socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cell_entry", %{"position" => pos, "value" => value}, socket)
      when is_binary(pos) do
    case Integer.parse(pos) do
      {int_pos, ""} ->
        handle_event("cell_entry", %{"position" => int_pos, "value" => value}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Cell focus (routed from GridKeyboard hook)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("cell_focus", %{"position" => pos}, socket) when is_integer(pos) do
    {:noreply, assign(socket, :focused_cell, pos)}
  end

  def handle_event("cell_focus", %{"position" => pos}, socket) when is_binary(pos) do
    case Integer.parse(pos) do
      {int_pos, ""} -> {:noreply, assign(socket, :focused_cell, int_pos)}
      _ -> {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Submit attempt
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("submit", _params, socket) do
    scope = socket.assigns.current_scope
    attempt = socket.assigns.attempt
    clues = socket.assigns.puzzle.clues
    grid = socket.assigns.grid

    # Assemble the 81-char submitted grid from clues + user entries.
    # Clue "0" positions use the user's entered value (or "0" if still blank).
    # The server rejects "0" digits via the 81-char [1-9]{81} regex.
    submitted = assemble_submitted_grid(clues, grid)

    case Attempts.submit_attempt(scope, attempt, submitted) do
      {:ok, completed} ->
        friend_times =
          Attempts.friend_times_for_puzzle(
            scope,
            socket.assigns.puzzle.id,
            socket.assigns.friend_ids
          )

        socket =
          socket
          |> assign(:attempt, completed)
          |> assign(:view_state, :completed)
          |> assign(:status_message, nil)
          |> assign(:friend_times, friend_times)

        {:noreply, socket}

      {:error, :incorrect_solution} ->
        {:noreply, assign(socket, :status_message, "That solution doesn't match.")}

      {:error, :validation, _changeset} ->
        {:noreply, assign(socket, :status_message, "Fill in every cell before submitting.")}

      {:error, :not_in_progress} ->
        socket = load_attempt_state(socket, scope, socket.assigns.puzzle.id, clues)
        {:noreply, assign(socket, :status_message, "Attempt is not in progress.")}

      {:error, :already_completed} ->
        socket = load_attempt_state(socket, scope, socket.assigns.puzzle.id, clues)
        {:noreply, assign(socket, :status_message, nil)}

      {:error, error_tag} when error_tag in [:forbidden, :not_found] ->
        {:noreply, assign(socket, :status_message, "Unable to submit. Please refresh.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Input mode toggle (session-only, not persisted to DB)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_input_mode", _params, socket) do
    new_mode =
      case socket.assigns.input_mode do
        :pointer -> :touch
        :touch -> :pointer
      end

    {:noreply, assign(socket, :input_mode, new_mode)}
  end

  @impl true
  def handle_event("input_mode:detect", %{"mode" => "touch"}, socket) do
    {:noreply, assign(socket, :input_mode, :touch)}
  end

  def handle_event("input_mode:detect", %{"mode" => "pointer"}, socket) do
    {:noreply, assign(socket, :input_mode, :pointer)}
  end

  def handle_event("input_mode:detect", _params, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="puzzle-show"
        class="mx-auto max-w-xl px-4 py-8"
        phx-hook=".InputModeDetect"
      >
        <%!-- Puzzle metadata header --%>
        <div class="mb-4 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/puzzles"} class="text-sm text-indigo-600 hover:underline">
              &larr; All Puzzles
            </.link>
            <span class={[
              "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
              difficulty_badge_class(@puzzle.difficulty)
            ]}>
              {@puzzle.difficulty}
            </span>
          </div>
          <span class="text-sm text-gray-500">{@puzzle.givens_count} givens</span>
        </div>

        <%!-- aria-live region for status announcements and errors --%>
        <div
          id="status-region"
          aria-live="polite"
          aria-atomic="true"
          class="mb-4 min-h-[1.5rem] text-sm font-medium"
        >
          <%= if @status_message do %>
            <p class={[
              "rounded-md px-3 py-2",
              status_message_class(@status_message)
            ]}>
              {@status_message}
            </p>
          <% end %>
        </div>

        <%!-- State machine branches --%>
        <%= cond do %>
          <% @view_state == :start -> %>
            <div class="rounded-lg border border-gray-200 bg-white shadow-sm p-8 text-center">
              <h1 class="text-xl font-bold text-gray-900 mb-2">Ready to solve?</h1>
              <p class="text-gray-500 mb-6 text-sm">
                Difficulty: <strong>{@puzzle.difficulty}</strong>
                &middot; {@puzzle.givens_count} givens
              </p>
              <button
                type="button"
                data-test="start-button"
                phx-click="start"
                class="inline-flex items-center rounded-lg bg-indigo-600 px-6 py-3 text-sm font-semibold text-white shadow hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 transition-colors"
              >
                Start
              </button>
            </div>
          <% @view_state == :playing -> %>
            <div class="flex items-center justify-between mb-4">
              <%!-- Timer display — driven by Timer JS hook; display-only --%>
              <div
                id="timer-display"
                data-test="timer-display"
                data-accumulated={@attempt.accumulated_seconds}
                data-segment-started-at={format_datetime(@attempt.segment_started_at)}
                phx-hook=".Timer"
                phx-update="ignore"
                class="font-mono text-2xl font-bold text-gray-800 tabular-nums"
              >
                0:00
              </div>

              <div class="flex gap-2">
                <%!-- Input mode toggle (session-only) --%>
                <button
                  type="button"
                  data-test="input-mode-toggle"
                  phx-click="toggle_input_mode"
                  class="rounded-lg border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-600 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 transition-colors"
                  aria-label={"Switch to #{if @input_mode == :pointer, do: "touch", else: "pointer"} mode"}
                >
                  {if @input_mode == :pointer, do: "Touch mode", else: "Pointer mode"}
                </button>

                <button
                  type="button"
                  data-test="pause-button"
                  phx-click="pause"
                  class="rounded-lg border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-600 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 transition-colors"
                >
                  Pause
                </button>
              </div>
            </div>

            <%!-- ARIA Sudoku grid --%>
            <div
              id="sudoku-grid"
              role="grid"
              aria-label="Sudoku puzzle"
              data-test="sudoku-grid"
              data-input-mode={to_string(@input_mode)}
              phx-hook=".GridKeyboard"
              class="grid grid-cols-9 border-2 border-gray-800 rounded-sm select-none"
            >
              <%= for row <- 0..8 do %>
                <div role="row" class="contents">
                  <%= for col <- 0..8 do %>
                    <% pos = row * 9 + col %>
                    <% clue_digit = String.at(@puzzle.clues, pos) %>
                    <% is_given = clue_digit != "0" %>
                    <% cell_value = Enum.at(@grid, pos) %>
                    <% display_value = if is_given, do: clue_digit, else: cell_value %>
                    <% is_focused = @focused_cell == pos %>
                    <% label = cell_aria_label(row, col, is_given, display_value) %>
                    <button
                      type="button"
                      role="gridcell"
                      data-test="grid-cell"
                      data-position={pos}
                      aria-label={label}
                      aria-readonly={to_string(is_given)}
                      tabindex={if is_focused, do: "0", else: "-1"}
                      phx-click={if not is_given, do: "cell_focus"}
                      phx-value-position={if not is_given, do: pos}
                      class={[
                        "relative flex items-center justify-center aspect-square text-base font-medium",
                        "focus:outline-none focus:ring-2 focus:ring-inset focus:ring-indigo-500",
                        "border border-gray-300",
                        box_border_class(row, col),
                        if(is_given,
                          do: "bg-gray-100 text-gray-900 font-bold cursor-default",
                          else: "bg-white text-indigo-700 hover:bg-indigo-50 cursor-pointer"
                        ),
                        if(is_focused and not is_given,
                          do: "ring-2 ring-inset ring-indigo-500",
                          else: ""
                        )
                      ]}
                    >
                      <%= if is_given do %>
                        <span aria-hidden="true">{clue_digit}</span>
                      <% else %>
                        <span aria-hidden="true">
                          {if display_value != "0", do: display_value, else: ""}
                        </span>
                      <% end %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Hidden input; the GridKeyboard hook focuses it on a touch tap to summon the native numeric keyboard, routing the typed digit to cell_entry. --%>
            <input
              id="mobile-entry"
              data-test="mobile-entry"
              type="text"
              inputmode="numeric"
              autocomplete="off"
              aria-hidden="true"
              tabindex="-1"
              class="fixed left-0 top-0 h-px w-px opacity-0"
            />

            <%!-- Number pad — pointer/desktop only. On touch the native numeric keyboard (summoned on cell tap) is the input method; an on-screen pad would dock beneath that keyboard and is omitted. --%>
            <%= if @input_mode == :pointer do %>
              <div class="mt-4 grid grid-cols-9 gap-1" aria-label="Number pad">
                <%= for digit <- 1..9 do %>
                  <button
                    type="button"
                    data-test="numpad-button"
                    phx-click="cell_entry"
                    phx-value-position={@focused_cell}
                    phx-value-value={Integer.to_string(digit)}
                    class="flex h-11 min-h-[44px] w-full items-center justify-center rounded-lg bg-gray-100 text-sm font-semibold text-gray-700 hover:bg-indigo-100 focus:outline-none focus:ring-2 focus:ring-indigo-500 transition-colors"
                    aria-label={"Enter #{digit}"}
                  >
                    {digit}
                  </button>
                <% end %>
              </div>
            <% end %>

            <%!-- Submit button --%>
            <div class="mt-6 flex justify-end">
              <button
                type="button"
                data-test="submit-button"
                phx-click="submit"
                class="inline-flex items-center rounded-lg bg-green-600 px-6 py-3 text-sm font-semibold text-white shadow hover:bg-green-700 focus:outline-none focus:ring-2 focus:ring-green-500 focus:ring-offset-2 transition-colors"
              >
                Submit Solution
              </button>
            </div>
          <% @view_state == :paused -> %>
            <div class="rounded-lg border border-gray-200 bg-white shadow-sm p-8 text-center">
              <h2 class="text-xl font-bold text-gray-900 mb-2">Paused</h2>
              <p class="text-gray-500 mb-6 text-sm">Your progress is saved. Resume when ready.</p>
              <button
                type="button"
                data-test="resume-button"
                phx-click="resume"
                class="inline-flex items-center rounded-lg bg-indigo-600 px-6 py-3 text-sm font-semibold text-white shadow hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 transition-colors"
              >
                Resume
              </button>
            </div>
          <% @view_state == :completed -> %>
            <div class="rounded-lg border border-green-200 bg-green-50 shadow-sm p-8">
              <h2 class="text-xl font-bold text-green-800 mb-2 text-center">Solved!</h2>

              <%!-- My time --%>
              <div class="text-center mb-6">
                <p class="text-gray-600 mb-2 text-sm">Your time:</p>
                <div
                  class="text-4xl font-mono font-bold text-green-700"
                  data-test="my-time"
                  data-test2="completed-time"
                >
                  {format_elapsed(@attempt.elapsed_seconds)}
                </div>
              </div>

              <%!-- Friend times (only rendered when assign is present — i.e. view_state == :completed) --%>
              <%= if @friend_times != [] do %>
                <div
                  class="mb-6"
                  data-test="friend-times-table"
                  aria-label="Friend times for this puzzle"
                >
                  <h3 class="text-sm font-semibold text-gray-700 mb-2">Friend times:</h3>
                  <ul class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white">
                    <%= for entry <- @friend_times do %>
                      <li
                        class="flex items-center justify-between px-4 py-2 text-sm"
                        data-test="friend-time-row"
                      >
                        <span class="text-gray-700 truncate">{entry.user.email}</span>
                        <span class="font-mono text-gray-900 ml-4">
                          {format_elapsed(entry.elapsed_seconds)}
                        </span>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <div class="text-center">
                <.link
                  navigate={~p"/puzzles"}
                  class="inline-flex items-center rounded-lg bg-indigo-600 px-6 py-3 text-sm font-semibold text-white shadow hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 transition-colors"
                >
                  Back to Puzzles
                </.link>
              </div>
            </div>
          <% true -> %>
            <%!-- Fallback: should not be reached --%>
            <div class="text-gray-500 text-sm">Loading&hellip;</div>
        <% end %>
      </div>
    </Layouts.app>

    <%!-- Colocated JS hooks — thin browser bridges, no game logic --%>

    <%!--
      .Timer hook: receives "timer:seed" push_event from the server on every
      transition to :in_progress (start + resume). Reads accumulated_seconds and
      segment_started_at, then drives a setInterval tick updating the display.
    --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Timer">
      export default {
        mounted() {
          this._interval = null;
          this.handleEvent("timer:seed", ({ accumulated_seconds, segment_started_at }) => {
            this._seed(accumulated_seconds, segment_started_at);
          });
        },
        _seed(accumulatedSeconds, segmentStartedAt) {
          if (this._interval) clearInterval(this._interval);
          const base = parseInt(accumulatedSeconds, 10) || 0;
          const started = segmentStartedAt ? new Date(segmentStartedAt) : null;
          const tick = () => {
            const elapsed = started
              ? base + Math.floor((Date.now() - started.getTime()) / 1000)
              : base;
            const m = Math.floor(elapsed / 60);
            const s = String(elapsed % 60).padStart(2, "0");
            this.el.textContent = `${m}:${s}`;
          };
          tick();
          this._interval = setInterval(tick, 1000);
        },
        destroyed() {
          if (this._interval) clearInterval(this._interval);
        }
      }
    </script>

    <%!--
      .GridKeyboard hook: routes input from the grid to server-side cell_focus
      and cell_entry handlers. Three thin sources, no validation logic:
        - physical keyboard (arrows, digits, backspace) on the focused cell;
        - touch tap, which focuses the hidden #mobile-entry input within the
          gesture so the device's native numeric keyboard appears;
        - that hidden input's typed digit, routed to the tapped cell.
    --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GridKeyboard">
      export default {
        mounted() {
          this.entryPos = null;
          this.entryInput = document.getElementById("mobile-entry");

          this.el.addEventListener("keydown", (e) => {
            const active = document.activeElement;
            const pos = active && active.dataset.position !== undefined
              ? parseInt(active.dataset.position, 10)
              : null;
            if (pos === null) return;

            const arrowMoves = {
              ArrowUp: pos - 9,
              ArrowDown: pos + 9,
              ArrowLeft: pos - 1,
              ArrowRight: pos + 1,
            };

            if (arrowMoves[e.key] !== undefined) {
              e.preventDefault();
              const next = arrowMoves[e.key];
              if (next >= 0 && next < 81) {
                this.pushEvent("cell_focus", { position: next });
              }
            } else if (e.key >= "1" && e.key <= "9") {
              this.pushEvent("cell_entry", { position: pos, value: e.key });
            } else if (e.key === "Backspace" || e.key === "Delete" || e.key === "0") {
              this.pushEvent("cell_entry", { position: pos, value: "0" });
            }
          });

          // Keep the active cell visible above the on-screen keyboard. The
          // focused element is the off-screen #mobile-entry input, so the
          // browser won't scroll the board for us — nudge it ourselves using
          // the visual viewport (which shrinks when the keyboard is shown).
          this.scrollActiveCellIntoView = () => {
            if (this.entryPos === null) return;
            const cell = this.el.querySelector('[data-position="' + this.entryPos + '"]');
            if (!cell) return;
            const vv = window.visualViewport;
            const rect = cell.getBoundingClientRect();
            const margin = 24;
            if (vv) {
              const visibleBottom = vv.offsetTop + vv.height;
              const overlap = rect.bottom - visibleBottom + margin;
              if (overlap > 0) window.scrollBy({ top: overlap, behavior: "smooth" });
            } else {
              cell.scrollIntoView({ block: "center", behavior: "smooth" });
            }
          };

          if (window.visualViewport) {
            this.onViewportResize = () => this.scrollActiveCellIntoView();
            window.visualViewport.addEventListener("resize", this.onViewportResize);
          }

          // Touch: tapping an editable cell summons the native numeric keyboard
          // by focusing the hidden input inside the user gesture.
          this.el.addEventListener("click", (e) => {
            if (this.el.dataset.inputMode !== "touch" || !this.entryInput) return;
            const cell = e.target.closest("[data-position]");
            if (!cell || cell.getAttribute("aria-readonly") === "true") return;
            this.entryPos = parseInt(cell.dataset.position, 10);
            this.entryInput.value = "";
            this.entryInput.focus();
            // The keyboard animates in; nudge the cell above it once shown.
            setTimeout(() => this.scrollActiveCellIntoView(), 300);
          });

          if (this.entryInput) {
            this.entryInput.addEventListener("input", () => {
              if (this.entryPos === null) return;
              const digit = this.entryInput.value.slice(-1);
              this.entryInput.value = "";
              if (digit >= "1" && digit <= "9") {
                this.pushEvent("cell_entry", { position: this.entryPos, value: digit });
              }
            });
            this.entryInput.addEventListener("keydown", (e) => {
              if (this.entryPos === null) return;
              if (e.key === "Backspace" || e.key === "Delete") {
                this.pushEvent("cell_entry", { position: this.entryPos, value: "0" });
              }
            });
          }
        },
        destroyed() {
          if (window.visualViewport && this.onViewportResize) {
            window.visualViewport.removeEventListener("resize", this.onViewportResize);
          }
        }
      }
    </script>

    <%!--
      .InputModeDetect hook: detects coarse pointer (touch) vs. fine pointer (mouse)
      and pushes input_mode:detect to the server once on mount. Session-only.
    --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InputModeDetect">
      export default {
        mounted() {
          const coarse = window.matchMedia("(pointer: coarse)").matches;
          this.pushEvent("input_mode:detect", { mode: coarse ? "touch" : "pointer" });
        }
      }
    </script>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Load the current attempt for this user+puzzle and set view_state + grid assigns.
  # Called on mount and on state re-sync after stale errors.
  defp load_attempt_state(socket, scope, puzzle_id, clues) do
    case Attempts.get_owner_attempt_for_puzzle(scope, puzzle_id) do
      {:ok, attempt} ->
        {view_state, grid, focused} = state_from_attempt(attempt, clues)

        socket =
          socket
          |> assign(:attempt, attempt)
          |> assign(:view_state, view_state)
          |> assign(:grid, grid)
          |> assign(:focused_cell, focused)

        socket =
          if view_state == :completed do
            friend_ids = Map.get(socket.assigns, :friend_ids, [])

            friend_times =
              Attempts.friend_times_for_puzzle(scope, puzzle_id, friend_ids)

            assign(socket, :friend_times, friend_times)
          else
            socket
          end

        if view_state == :playing do
          push_timer_seed(socket, attempt)
        else
          socket
        end

      {:error, :not_found} ->
        socket
        |> assign(:attempt, nil)
        |> assign(:view_state, :start)
        |> assign(:grid, build_grid(clues))
        |> assign(:focused_cell, first_editable_index(clues))
    end
  end

  # Restore the saved board (entries) so refreshes/deploys keep progress; fall
  # back to clues for attempts started before entries were persisted.
  defp state_from_attempt(%{status: :in_progress} = attempt, clues) do
    {:playing, build_grid(attempt.entries || clues), first_editable_index(clues)}
  end

  defp state_from_attempt(%{status: :paused} = attempt, clues) do
    {:paused, build_grid(attempt.entries || clues), first_editable_index(clues)}
  end

  defp state_from_attempt(%{status: :completed} = attempt, clues) do
    {:completed, build_grid(attempt.entries || clues), nil}
  end

  # Build the grid as a list of 81 strings.
  # Given cells carry their digit; blank cells carry "0".
  defp build_grid(clues) do
    String.graphemes(clues)
  end

  # Returns the index of the first editable (non-given) cell.
  defp first_editable_index(clues) do
    clues
    |> String.graphemes()
    |> Enum.find_index(&(&1 == "0"))
    |> Kernel.||(0)
  end

  # Assemble the 81-char grid to submit to the server.
  # Clue positions use the clue digit; blank positions use the user's entry (or "0" if still blank).
  defp assemble_submitted_grid(clues, grid) do
    clues
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn {clue_digit, i} ->
      if clue_digit != "0" do
        clue_digit
      else
        Enum.at(grid, i)
      end
    end)
  end

  # Push timer seed data to the client via pushEvent so the Timer hook can
  # compute the running display. Called on every transition to :in_progress
  # (both initial start and resume) so the hook is always re-seeded correctly.
  defp push_timer_seed(socket, attempt) do
    push_event(socket, "timer:seed", %{
      accumulated_seconds: attempt.accumulated_seconds,
      segment_started_at: format_datetime(attempt.segment_started_at)
    })
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_elapsed(nil), do: "0:00"

  defp format_elapsed(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp cell_aria_label(row, col, true = _is_given, value) do
    "Row #{row + 1}, column #{col + 1}, given #{value}"
  end

  defp cell_aria_label(row, col, false = _is_given, "0") do
    "Row #{row + 1}, column #{col + 1}, empty"
  end

  defp cell_aria_label(row, col, false = _is_given, value) do
    "Row #{row + 1}, column #{col + 1}, value #{value}"
  end

  # CSS border class for 3x3 box visual grouping.
  defp box_border_class(row, col) do
    right_border = if rem(col, 3) == 2 and col != 8, do: "border-r-2 border-r-gray-700", else: ""
    bottom_border = if rem(row, 3) == 2 and row != 8, do: "border-b-2 border-b-gray-700", else: ""
    "#{right_border} #{bottom_border}"
  end

  defp difficulty_badge_class(:easy), do: "bg-green-100 text-green-800"
  defp difficulty_badge_class(:medium), do: "bg-yellow-100 text-yellow-800"
  defp difficulty_badge_class(:hard), do: "bg-red-100 text-red-800"

  defp status_message_class(msg) do
    if msg in ["That solution doesn't match.", "Fill in every cell before submitting."] do
      "bg-red-50 text-red-700"
    else
      "bg-blue-50 text-blue-700"
    end
  end
end
