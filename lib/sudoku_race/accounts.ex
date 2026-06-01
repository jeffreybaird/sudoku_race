defmodule SudokuRace.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias SudokuRace.Repo

  alias SudokuRace.Accounts.{User, UserNotifier, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Returns a changeset for the registration form.

  Skips password hashing and uniqueness lookups so it is cheap to run on every
  `phx-change` keystroke.
  """
  def change_user_registration(user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    # Accounts are usable immediately — no email confirmation / magic link.
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
  end

  ## Admin

  @doc """
  Returns true if the user has the admin role.

  ## Examples

      iex> SudokuRace.Accounts.admin?(%SudokuRace.Accounts.User{is_admin: true})
      true

      iex> SudokuRace.Accounts.admin?(%SudokuRace.Accounts.User{is_admin: false})
      false

      iex> SudokuRace.Accounts.admin?(nil)
      false

  """
  def admin?(%User{is_admin: true}), do: true
  def admin?(_user), do: false

  @doc """
  Grants the admin role to the user with the given email.

  Returns `{:ok, user}` or `{:error, :not_found}`. Used by the
  `mix sudoku_race.grant_admin` task (dev) and `SudokuRace.Release.grant_admin/1`
  (prod, via `bin/sudoku_race eval`).
  """
  def grant_admin_by_email(email) when is_binary(email) do
    case get_user_by_email(email) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Ecto.Changeset.change(is_admin: true)
        |> Repo.update()
    end
  end

  @doc """
  Returns a paginated list of all users (admin user management).

  ## Options

    * `:page` — 1-based page (default: 1)
    * `:per_page` — results per page, capped at 100 (default: 20)
  """
  def list_users(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, 20) |> min(100)
    offset = (page - 1) * per_page

    User
    |> order_by([u], asc: u.email)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Resets `target_user_id`'s password on behalf of an admin.

  The acting user's admin status is re-checked against the database (by id), so
  a stale or forged scope cannot authorize the change. On success the target's
  existing sessions are expired (they are logged out everywhere); the admin's own
  session is unaffected.

  Returns `{:ok, {user, expired_tokens}}`.
  Returns `{:error, :unauthorized}` if the acting user is not (or is no longer) an admin.
  Returns `{:error, :not_found}` if the target user does not exist.
  Returns `{:error, :validation, changeset}` if the new password is invalid.
  """
  def admin_reset_password(acting_user_id, target_user_id, attrs) do
    with {:ok, _admin} <- require_admin(acting_user_id),
         {:ok, target} <- fetch_user(target_user_id) do
      case update_user_password(target, attrs) do
        {:ok, result} -> {:ok, result}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, :validation, changeset}
      end
    end
  end

  defp require_admin(user_id) do
    case Repo.get(User, user_id) do
      %User{is_admin: true} = admin -> {:ok, admin}
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.

  ## Examples

      iex> SudokuRace.Accounts.sudo_mode?(%SudokuRace.Accounts.User{authenticated_at: nil})
      false

  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `SudokuRace.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `SudokuRace.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
