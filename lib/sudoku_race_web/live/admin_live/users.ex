defmodule SudokuRaceWeb.AdminLive.Users do
  @moduledoc """
  Admin-only user management: list users and reset a user's password.

  Access is gated in the router by `:require_authenticated`, `:require_admin`,
  and `:require_sudo_mode`. The password reset re-verifies admin status against
  the database in `Accounts.admin_reset_password/3` (defence in depth).
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Accounts

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:reset_error, nil)
     |> assign(:reset_target_id, nil)
     |> load_users()}
  end

  @impl true
  def handle_event("reset_password", %{"user_id" => id, "password" => password}, socket) do
    admin_id = socket.assigns.current_scope.user.id

    case Accounts.admin_reset_password(admin_id, String.to_integer(id), %{password: password}) do
      {:ok, {user, _expired}} ->
        {:noreply,
         socket
         |> assign(:reset_error, nil)
         |> assign(:reset_target_id, nil)
         |> put_flash(:info, "Password reset for #{user.email}.")
         |> load_users()}

      {:error, :validation, changeset} ->
        message = changeset |> password_error() || "Invalid password."

        {:noreply,
         socket
         |> assign(:reset_error, message)
         |> assign(:reset_target_id, String.to_integer(id))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to do that.")
         |> redirect(to: ~p"/")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That user no longer exists.")
         |> load_users()}
    end
  end

  defp load_users(socket) do
    assign(socket, :users, Accounts.list_users(per_page: @per_page))
  end

  defp password_error(changeset) do
    case changeset.errors[:password] do
      {msg, opts} -> "Password " <> interpolate_error(msg, opts)
      _ -> nil
    end
  end

  # Substitute Ecto error placeholders, e.g. "%{count}" → "12".
  defp interpolate_error(msg, opts) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl px-4 py-8">
        <h1 class="text-2xl font-bold text-gray-900 mb-2">User administration</h1>
        <p class="text-sm text-gray-500 mb-6">Reset a user's password.</p>

        <div
          data-test="admin-user-list"
          class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white shadow-sm"
        >
          <div
            :for={user <- @users}
            data-test="admin-user-row"
            class="px-6 py-4"
          >
            <div class="flex items-center justify-between gap-4">
              <span class="text-sm text-gray-900" data-test="admin-user-email">
                {user.email}
                <span :if={user.is_admin} class="ml-2 text-xs font-medium text-indigo-600">
                  (admin)
                </span>
              </span>
            </div>
            <form
              id={"reset-form-#{user.id}"}
              phx-submit="reset_password"
              data-test="reset-password-form"
              class="mt-2 flex flex-col gap-2 sm:flex-row sm:items-start"
            >
              <input type="hidden" name="user_id" value={user.id} />
              <div class="flex-1">
                <label for={"new-password-#{user.id}"} class="sr-only">
                  New password for {user.email}
                </label>
                <input
                  type="password"
                  id={"new-password-#{user.id}"}
                  name="password"
                  required
                  autocomplete="new-password"
                  data-test="reset-password-input"
                  placeholder="New password"
                  aria-describedby={
                    @reset_target_id == user.id && @reset_error && "reset-error-#{user.id}"
                  }
                  aria-invalid={@reset_target_id == user.id && @reset_error != nil}
                  class="block w-full min-h-[44px] rounded-lg border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                />
                <p
                  :if={@reset_target_id == user.id && @reset_error}
                  id={"reset-error-#{user.id}"}
                  data-test="reset-password-error"
                  class="mt-1 flex items-center gap-1 text-sm text-red-700"
                >
                  <span aria-hidden="true">⚠</span>
                  <span>{@reset_error}</span>
                </p>
              </div>
              <button
                type="submit"
                data-test="reset-password-button"
                phx-disable-with="Resetting..."
                class="min-h-[44px] rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                aria-label={"Reset password for #{user.email}"}
              >
                Reset password
              </button>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
