defmodule SudokuRace.Social do
  @moduledoc """
  Context for friendships between users.

  Friendship is one-to-one and symmetric — no groups, no leaderboards, no chat.

  ## State machine

      send_friend_request → :pending
      :pending → accept_friend_request → :accepted
      :pending → decline_friend_request → (deleted)

  ## Race-safe uniqueness

  The `friendships_pair_index` functional unique index ensures that A→B and
  B→A cannot both exist concurrently. Pre-checks guard against common races and
  return friendly tagged errors; the DB constraint is the authoritative backstop.

  ## Authorization model

  All public functions accept a `scope` as the first argument. The scope's
  `.user` field is the acting principal. Functions reject actions the principal
  is not authorized to perform with `{:error, :forbidden}`.
  """

  import Ecto.Query

  alias SudokuRace.Accounts
  alias SudokuRace.Accounts.Scope
  alias SudokuRace.Accounts.User
  alias SudokuRace.Repo
  alias SudokuRace.Social.Friendship

  @max_per_page 100
  @default_per_page 20

  # PostgreSQL int4 max value.
  @int4_max 2_147_483_647

  # ---------------------------------------------------------------------------
  # send_friend_request/2
  # ---------------------------------------------------------------------------

  @doc """
  Sends a friend request from the scoped user to the user with the given email.

  ## Return values

  - `{:ok, friendship}` (status `:pending`) on success.
  - `{:error, :not_found}` if no user has that email.
  - `{:error, :cannot_befriend_self}` if the email belongs to the current user.
  - `{:error, :already_friends}` if an accepted friendship already exists
    (either direction).
  - `{:error, :already_requested}` if the current user already has a pending
    request to that user.
  - `{:error, :request_exists, request_id}` if a pending request from the OTHER
    user to the current user already exists. The returned `request_id` can be
    passed directly to `accept_friend_request/2` to accept it.
  """
  @spec send_friend_request(Scope.t(), String.t()) ::
          {:ok, Friendship.t()}
          | {:error, :not_found}
          | {:error, :cannot_befriend_self}
          | {:error, :already_friends}
          | {:error, :already_requested}
          | {:error, :request_exists, integer()}
  def send_friend_request(%Scope{} = scope, email) when is_binary(email) do
    with {:ok, other_user} <- lookup_user_by_email(email),
         :ok <- reject_self_request(scope, other_user),
         :ok <- reject_if_already_friends(scope.user.id, other_user.id),
         :ok <- reject_if_pending_request_exists(scope.user.id, other_user.id) do
      insert_friend_request(scope.user.id, other_user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # accept_friend_request/2
  # ---------------------------------------------------------------------------

  @doc """
  Accepts a pending friend request.

  Only the ADDRESSEE of the request may accept it.

  Returns `{:ok, friendship}` (status `:accepted`) on success.
  Returns `{:error, :already_accepted}` if the friendship is already accepted
  (following the same precedent as `Attempts` returning `:already_completed`).
  Returns `{:error, :forbidden}` if the current user is not the addressee.
  Returns `{:error, :not_found}` if the request does not exist, or the id is
  invalid (string that cannot be parsed, out-of-range integer, etc.).
  """
  @spec accept_friend_request(Scope.t(), integer() | String.t()) ::
          {:ok, Friendship.t()}
          | {:error, :already_accepted}
          | {:error, :forbidden}
          | {:error, :not_found}
  def accept_friend_request(%Scope{} = scope, request_id) do
    with {:ok, friendship} <- load_friendship(request_id),
         :ok <- require_addressee(scope, friendship),
         :ok <- require_pending(friendship) do
      friendship
      |> Friendship.update_changeset(%{status: :accepted})
      |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # decline_friend_request/2
  # ---------------------------------------------------------------------------

  @doc """
  Declines a pending friend request by deleting the row.

  Only the ADDRESSEE of the request may decline it.
  A declined request can be re-sent by the original requester.

  Returns `{:ok, friendship}` on success (the now-deleted struct is returned
  for caller convenience).
  Returns `{:error, :forbidden}` if the current user is not the addressee.
  Returns `{:error, :not_found}` if the request does not exist.
  """
  @spec decline_friend_request(Scope.t(), integer() | String.t()) ::
          {:ok, Friendship.t()}
          | {:error, :forbidden}
          | {:error, :not_found}
  def decline_friend_request(%Scope{} = scope, request_id) do
    with {:ok, friendship} <- load_friendship(request_id),
         :ok <- require_addressee(scope, friendship) do
      Repo.delete(friendship)
    end
  end

  # ---------------------------------------------------------------------------
  # list_friends/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of `%User{}` structs for the current user's accepted
  friends. Both directions (current user as requester or addressee) are included.

  ## Options

  - `:page`     — 1-based page number (default: 1)
  - `:per_page` — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  """
  @spec list_friends(Scope.t(), keyword()) :: [User.t()]
  def list_friends(%Scope{} = scope, opts \\ []) do
    {_page, per_page, offset} = pagination_params(opts)
    user_id = scope.user.id

    # Fetch friends where current user is the requester
    as_requester =
      from f in Friendship,
        join: u in User,
        on: u.id == f.addressee_id,
        where: f.requester_id == ^user_id and f.status == :accepted,
        select: u

    # Fetch friends where current user is the addressee
    as_addressee =
      from f in Friendship,
        join: u in User,
        on: u.id == f.requester_id,
        where: f.addressee_id == ^user_id and f.status == :accepted,
        select: u

    union_query =
      from u in subquery(union_all(as_requester, ^as_addressee)),
        order_by: u.id,
        limit: ^per_page,
        offset: ^offset

    Repo.all(union_query)
  end

  # ---------------------------------------------------------------------------
  # list_pending_requests/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of incoming pending friend requests where the current
  user is the addressee. The `:requester` association is preloaded so callers can
  display who sent each request.

  ## Options

  - `:page`     — 1-based page number (default: 1)
  - `:per_page` — results per page, capped at #{@max_per_page} (default: #{@default_per_page})
  """
  @spec list_pending_requests(Scope.t(), keyword()) :: [Friendship.t()]
  def list_pending_requests(%Scope{} = scope, opts \\ []) do
    {_page, per_page, offset} = pagination_params(opts)

    Friendship
    |> where([f], f.addressee_id == ^scope.user.id and f.status == :pending)
    |> order_by([f], asc: f.id)
    |> limit(^per_page)
    |> offset(^offset)
    |> preload(:requester)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # friends?/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the scoped user and the given user (or user id) have an
  accepted friendship in either direction.
  """
  @spec friends?(Scope.t(), User.t() | integer()) :: boolean()
  def friends?(%Scope{} = scope, %User{id: other_id}) do
    friends?(scope, other_id)
  end

  def friends?(%Scope{} = scope, other_id) when is_integer(other_id) do
    user_id = scope.user.id

    Repo.exists?(
      from f in Friendship,
        where:
          f.status == :accepted and
            ((f.requester_id == ^user_id and f.addressee_id == ^other_id) or
               (f.requester_id == ^other_id and f.addressee_id == ^user_id))
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup_user_by_email(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp reject_self_request(%Scope{} = scope, %User{id: other_id}) do
    if scope.user.id == other_id do
      {:error, :cannot_befriend_self}
    else
      :ok
    end
  end

  defp reject_if_already_friends(user_id, other_id) do
    exists? =
      Repo.exists?(
        from f in Friendship,
          where:
            f.status == :accepted and
              ((f.requester_id == ^user_id and f.addressee_id == ^other_id) or
                 (f.requester_id == ^other_id and f.addressee_id == ^user_id))
      )

    if exists?, do: {:error, :already_friends}, else: :ok
  end

  defp reject_if_pending_request_exists(user_id, other_id) do
    # Check if current user already sent a pending request to other
    my_pending =
      Repo.get_by(Friendship,
        requester_id: user_id,
        addressee_id: other_id,
        status: "pending"
      )

    if my_pending do
      {:error, :already_requested}
    else
      # Check if other user has a pending request to current user
      their_pending =
        Repo.get_by(Friendship,
          requester_id: other_id,
          addressee_id: user_id,
          status: "pending"
        )

      if their_pending do
        {:error, :request_exists, their_pending.id}
      else
        :ok
      end
    end
  end

  defp insert_friend_request(user_id, other_id) do
    %Friendship{requester_id: user_id, addressee_id: other_id}
    |> Friendship.create_changeset(%{status: :pending})
    |> Repo.insert()
    |> map_friendship_constraint_errors(user_id, other_id)
  end

  # Exposed as a named function (not defp) so that tests can exercise each
  # cond arm directly — the pre-checks in send_friend_request/2 short-circuit
  # before Repo.insert, so the constraint backstop cannot be reached from the
  # public API in tests. This is the same test-seam pattern used for
  # resolve_pair_conflict/2.
  @doc false
  def map_friendship_constraint_errors({:ok, friendship}, _user_id, _other_id) do
    {:ok, friendship}
  end

  @doc false
  def map_friendship_constraint_errors(
        {:error, %Ecto.Changeset{} = changeset},
        user_id,
        other_id
      ) do
    cond do
      pair_unique_violated?(changeset) ->
        resolve_pair_conflict(user_id, other_id)

      self_check_violated?(changeset) ->
        {:error, :cannot_befriend_self}

      true ->
        {:error, :validation, changeset}
    end
  end

  # On a pair-unique constraint violation (race condition), reload the existing
  # row to determine the appropriate error.
  #
  # Exposed as a named function (not defp) so that tests can exercise each branch
  # directly — the race path cannot be reached from `send_friend_request` in tests
  # because the pre-checks fire first and short-circuit. This is the same test-seam
  # pattern used elsewhere in the project.
  @doc false
  def resolve_pair_conflict(user_id, other_id) do
    existing =
      Repo.one(
        from f in Friendship,
          where:
            (f.requester_id == ^user_id and f.addressee_id == ^other_id) or
              (f.requester_id == ^other_id and f.addressee_id == ^user_id)
      )

    case existing do
      nil ->
        # Shouldn't happen, but guard against a delete between constraint
        # violation and this reload.
        {:error, :not_found}

      %Friendship{status: :accepted} ->
        {:error, :already_friends}

      %Friendship{status: :pending, requester_id: ^user_id} ->
        {:error, :already_requested}

      %Friendship{status: :pending} = f ->
        {:error, :request_exists, f.id}
    end
  end

  defp pair_unique_violated?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :requester_id) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  defp self_check_violated?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :requester_id) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :check
      _ -> false
    end
  end

  defp load_friendship(id) when is_integer(id) and id > 0 and id <= @int4_max do
    case Repo.get(Friendship, id) do
      nil -> {:error, :not_found}
      friendship -> {:ok, friendship}
    end
  end

  defp load_friendship(id) when is_integer(id), do: {:error, :not_found}

  defp load_friendship(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 and int_id <= @int4_max ->
        load_friendship(int_id)

      _ ->
        {:error, :not_found}
    end
  end

  defp require_addressee(%Scope{} = scope, %Friendship{addressee_id: addressee_id}) do
    if scope.user.id == addressee_id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_pending(%Friendship{status: :pending}), do: :ok
  defp require_pending(%Friendship{status: :accepted}), do: {:error, :already_accepted}

  defp pagination_params(opts) do
    page = Keyword.get(opts, :page, 1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> min(@max_per_page)
    offset = (page - 1) * per_page
    {page, per_page, offset}
  end
end
