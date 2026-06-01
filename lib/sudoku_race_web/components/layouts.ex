defmodule SudokuRaceWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SudokuRaceWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-gray-200 bg-white">
      <nav
        class="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3 sm:px-6 lg:px-8"
        aria-label="Main navigation"
      >
        <.link
          navigate={~p"/"}
          data-test="nav-brand"
          class="text-lg font-bold text-gray-900 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 rounded"
        >
          Sudoku Race
        </.link>
        <ul class="flex items-center gap-1 text-sm sm:gap-2">
          <%= if @current_scope do %>
            <li>
              <.link navigate={~p"/puzzles"} data-test="nav-puzzles" class={nav_link_class()}>
                Puzzles
              </.link>
            </li>
            <li>
              <.link navigate={~p"/friends"} data-test="nav-friends" class={nav_link_class()}>
                Friends
              </.link>
            </li>
            <li>
              <.link navigate={~p"/leaderboard"} data-test="nav-leaderboard" class={nav_link_class()}>
                Leaderboard
              </.link>
            </li>
            <li :if={@current_scope.user.is_admin}>
              <.link navigate={~p"/admin/users"} data-test="nav-admin" class={nav_link_class()}>
                Admin
              </.link>
            </li>
            <li class="hidden px-2 text-gray-500 sm:block" data-test="nav-email">
              {@current_scope.user.email}
            </li>
            <li>
              <.link href={~p"/users/settings"} class={nav_link_class()}>Settings</.link>
            </li>
            <li>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                data-test="nav-logout"
                class={nav_link_class()}
              >
                Log out
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/log-in"} data-test="nav-login" class={nav_link_class()}>
                Log in
              </.link>
            </li>
            <li>
              <.link navigate={~p"/users/register"} data-test="nav-register" class={nav_link_class()}>
                Register
              </.link>
            </li>
          <% end %>
        </ul>
      </nav>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Shared style for the main-navigation links: visible focus ring per WCAG.
  defp nav_link_class do
    "rounded px-2 py-1 font-medium text-gray-700 hover:text-gray-900 hover:bg-gray-100 transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
