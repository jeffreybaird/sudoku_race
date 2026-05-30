defmodule SudokuRaceWeb.FriendLive.Index do
  @moduledoc """
  LiveView for managing friendships.

  Lets an authenticated user send a friend request by email, accept or decline
  incoming pending requests, and view their current friends. All data flows
  through the `Social` context — no `Repo` access here. No PubSub: friend lists
  reload after each mutation; only "friend solved a puzzle" justifies PubSub.
  """

  use SudokuRaceWeb, :live_view

  alias SudokuRace.Social

  @per_page 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:email_error, nil)
     |> assign_form()
     |> load_social()}
  end

  @impl true
  def handle_event("send_request", %{"email" => email}, socket) do
    case Social.send_friend_request(socket.assigns.current_scope, email) do
      {:ok, _friendship} ->
        {:noreply,
         socket
         |> assign(:email_error, nil)
         |> assign_form()
         |> put_flash(:info, "Friend request sent.")
         |> load_social()}

      {:error, :request_exists, _request_id} ->
        {:noreply,
         socket
         |> assign(:email_error, nil)
         |> put_flash(:info, "They already sent you a request — accept it below.")
         |> load_social()}

      {:error, reason} ->
        {:noreply, assign(socket, :email_error, send_error_message(reason))}
    end
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    case Social.accept_friend_request(socket.assigns.current_scope, id) do
      {:ok, _friendship} ->
        {:noreply,
         socket
         |> put_flash(:info, "Friend request accepted.")
         |> load_social()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, respond_error_message(reason))
         |> load_social()}
    end
  end

  @impl true
  def handle_event("decline", %{"id" => id}, socket) do
    case Social.decline_friend_request(socket.assigns.current_scope, id) do
      {:ok, _friendship} ->
        {:noreply,
         socket
         |> put_flash(:info, "Friend request declined.")
         |> load_social()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, respond_error_message(reason))
         |> load_social()}
    end
  end

  defp load_social(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:friends, Social.list_friends(scope, per_page: @per_page))
    |> assign(:pending_requests, Social.list_pending_requests(scope, per_page: @per_page))
  end

  defp assign_form(socket) do
    assign(socket, :form, to_form(%{"email" => ""}, as: "friend"))
  end

  defp send_error_message(:not_found), do: "No user found with that email."
  defp send_error_message(:cannot_befriend_self), do: "You cannot befriend yourself."
  defp send_error_message(:already_friends), do: "You are already friends."
  defp send_error_message(:already_requested), do: "You already sent them a request."

  defp respond_error_message(:already_accepted), do: "You are already friends."
  defp respond_error_message(:forbidden), do: "You are not allowed to do that."
  defp respond_error_message(:not_found), do: "That request no longer exists."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-4xl px-4 py-8">
        <h1 class="text-2xl font-bold text-gray-900 mb-6">Friends</h1>

        <%!-- Send a friend request --%>
        <section aria-labelledby="add-friend-heading" class="mb-8">
          <h2 id="add-friend-heading" class="text-lg font-semibold text-gray-900 mb-3">
            Add a friend
          </h2>
          <.form
            for={@form}
            id="add-friend-form"
            data-test="add-friend-form"
            phx-submit="send_request"
            class="flex flex-col gap-2 sm:flex-row sm:items-start"
          >
            <div class="flex-1">
              <label for="friend-email" class="sr-only">Friend's email address</label>
              <input
                type="email"
                id="friend-email"
                name="email"
                value={@form[:email].value}
                required
                data-test="friend-email-input"
                placeholder="friend@example.com"
                aria-describedby={@email_error && "friend-email-error"}
                aria-invalid={@email_error != nil}
                class="block w-full min-h-[44px] rounded-lg border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              />
              <p
                :if={@email_error}
                id="friend-email-error"
                data-test="friend-email-error"
                class="mt-1 flex items-center gap-1 text-sm text-red-700"
              >
                <span aria-hidden="true">⚠</span>
                <span>{@email_error}</span>
              </p>
            </div>
            <button
              type="submit"
              data-test="send-request-button"
              phx-disable-with="Sending..."
              class="min-h-[44px] rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
            >
              Send request
            </button>
          </.form>
        </section>

        <%!-- Incoming pending requests --%>
        <section aria-labelledby="requests-heading" class="mb-8">
          <h2 id="requests-heading" class="text-lg font-semibold text-gray-900 mb-3">
            Pending requests
          </h2>
          <div
            data-test="pending-requests"
            aria-live="polite"
            class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white shadow-sm"
          >
            <p
              :if={@pending_requests == []}
              data-test="no-pending-requests"
              class="px-6 py-8 text-center text-gray-500"
            >
              No pending requests.
            </p>
            <div
              :for={request <- @pending_requests}
              data-test="pending-request-row"
              class="flex items-center justify-between px-6 py-4"
            >
              <span class="text-sm text-gray-900" data-test="requester-email">
                {request.requester.email}
              </span>
              <div class="flex gap-2">
                <button
                  type="button"
                  data-test="accept-request-button"
                  phx-click="accept"
                  phx-value-id={request.id}
                  class="min-h-[44px] rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-emerald-500"
                  aria-label={"Accept friend request from #{request.requester.email}"}
                >
                  Accept
                </button>
                <button
                  type="button"
                  data-test="decline-request-button"
                  phx-click="decline"
                  phx-value-id={request.id}
                  class="min-h-[44px] rounded-lg bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-200 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-gray-500"
                  aria-label={"Decline friend request from #{request.requester.email}"}
                >
                  Decline
                </button>
              </div>
            </div>
          </div>
        </section>

        <%!-- Current friends --%>
        <section aria-labelledby="friends-heading">
          <h2 id="friends-heading" class="text-lg font-semibold text-gray-900 mb-3">
            Your friends
          </h2>
          <div
            data-test="friends-list"
            class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white shadow-sm"
          >
            <p
              :if={@friends == []}
              data-test="no-friends"
              class="px-6 py-8 text-center text-gray-500"
            >
              No friends yet. Send a request above.
            </p>
            <div
              :for={friend <- @friends}
              data-test="friend-row"
              class="flex items-center px-6 py-4"
            >
              <span class="text-sm text-gray-900" data-test="friend-email">
                {friend.email}
              </span>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
