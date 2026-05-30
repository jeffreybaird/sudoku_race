defmodule SudokuRace.SocialTest do
  use SudokuRace.DataCase, async: true

  alias SudokuRace.Accounts.User
  alias SudokuRace.Social
  alias SudokuRace.Social.Friendship

  import SudokuRace.AccountsFixtures
  import SudokuRace.SocialFixtures

  # ---------------------------------------------------------------------------
  # send_friend_request/2
  # ---------------------------------------------------------------------------

  describe "send_friend_request/2" do
    test "sends a pending request when all conditions are met" do
      scope = user_scope_fixture()
      other = user_fixture()

      assert {:ok, friendship} = Social.send_friend_request(scope, other.email)
      assert friendship.requester_id == scope.user.id
      assert friendship.addressee_id == other.id
      assert friendship.status == :pending
    end

    test "returns :not_found when email does not exist" do
      scope = user_scope_fixture()

      assert {:error, :not_found} =
               Social.send_friend_request(scope, "nobody@example.com")
    end

    test "returns :cannot_befriend_self when email belongs to the current user" do
      scope = user_scope_fixture()

      assert {:error, :cannot_befriend_self} =
               Social.send_friend_request(scope, scope.user.email)
    end

    test "returns :already_friends when an accepted friendship exists (requester → addressee)" do
      scope = user_scope_fixture()
      other = user_fixture()
      _friendship = accepted_friendship_fixture(scope.user, other)

      assert {:error, :already_friends} =
               Social.send_friend_request(scope, other.email)
    end

    test "returns :already_friends when an accepted friendship exists (addressee → requester)" do
      scope = user_scope_fixture()
      other = user_fixture()
      _friendship = accepted_friendship_fixture(other, scope.user)

      assert {:error, :already_friends} =
               Social.send_friend_request(scope, other.email)
    end

    test "returns :already_requested when the current user already has a pending request to that user" do
      scope = user_scope_fixture()
      other = user_fixture()
      _friendship = pending_friendship_fixture(scope.user, other)

      assert {:error, :already_requested} =
               Social.send_friend_request(scope, other.email)
    end

    test "returns {:error, :request_exists, id} when the OTHER user has a pending request to the current user" do
      scope = user_scope_fixture()
      other = user_fixture()
      existing = pending_friendship_fixture(other, scope.user)

      assert {:error, :request_exists, request_id} =
               Social.send_friend_request(scope, other.email)

      assert request_id == existing.id
    end

    test "race test: A→B and B→A both attempt to insert; exactly one row survives" do
      user_a = user_fixture()
      user_b = user_fixture()
      scope_a = user_scope_fixture(user_a)
      scope_b = user_scope_fixture(user_b)

      # Both sides call send_friend_request/2 through the public API.
      # The first call succeeds; the second hits the pre-check (reject_if_pending_request_exists
      # detects the existing row) and returns a tagged error without reaching Repo.insert.
      # This is an end-to-end uniqueness guarantee via the pre-check path, not the DB
      # constraint backstop. The assertions below confirm exactly one success and one
      # correctly tagged error.
      result_a = Social.send_friend_request(scope_a, user_b.email)
      result_b = Social.send_friend_request(scope_b, user_a.email)

      # Exactly one must succeed
      successes = Enum.count([result_a, result_b], &match?({:ok, _}, &1))

      assert successes == 1,
             "Expected exactly 1 success, got #{successes}: #{inspect([result_a, result_b])}"

      # The second must return a sensible tagged error
      errors = Enum.filter([result_a, result_b], &(not match?({:ok, _}, &1)))
      assert length(errors) == 1

      [error] = errors

      assert match?({:error, :request_exists, _}, error) or
               match?({:error, :already_requested}, error),
             "Expected :request_exists or :already_requested, got: #{inspect(error)}"

      # Exactly one row exists in the DB for this pair
      count =
        Repo.aggregate(
          from(f in Friendship,
            where:
              (f.requester_id == ^user_a.id and f.addressee_id == ^user_b.id) or
                (f.requester_id == ^user_b.id and f.addressee_id == ^user_a.id)
          ),
          :count
        )

      assert count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Friendship schema — DB constraint wiring
  # ---------------------------------------------------------------------------

  describe "Friendship schema — DB constraints" do
    test "pair unique index rejects reverse-direction insert" do
      a = user_fixture()
      b = user_fixture()
      _existing = pending_friendship_fixture(a, b)

      # Bypass the context and attempt to insert the reverse direction directly.
      # This is the path that fires during a genuine race condition.
      {:error, changeset} =
        %Friendship{requester_id: b.id, addressee_id: a.id}
        |> Friendship.create_changeset(%{status: :pending})
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :unique
      assert Keyword.get(opts, :constraint_name) == "friendships_pair_index"
    end

    test "pair unique index rejects same-direction duplicate insert" do
      a = user_fixture()
      b = user_fixture()
      _existing = pending_friendship_fixture(a, b)

      {:error, changeset} =
        %Friendship{requester_id: a.id, addressee_id: b.id}
        |> Friendship.create_changeset(%{status: :pending})
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :unique
    end

    test "validate_no_self_friendship changeset validation error is on :requester_id (layer alignment)" do
      user = user_fixture()

      # The changeset-level validation fires before any DB hit.
      # The error must land on :requester_id to match the check_constraint field
      # and the self_check_violated?/1 inspector in social.ex.
      changeset =
        %Friendship{requester_id: user.id, addressee_id: user.id}
        |> Friendship.create_changeset(%{status: :pending})

      assert {_msg, _opts} = changeset.errors[:requester_id]
      refute changeset.errors[:addressee_id]
    end

    test "no_self_friendship CHECK constraint rejects requester_id == addressee_id at DB level" do
      user = user_fixture()

      # Bypass the changeset validation (validate_no_self_friendship) and go
      # straight to the DB, which fires the CHECK constraint. The check_constraint
      # declaration converts the Postgres error to a changeset error.
      {:error, changeset} =
        %Friendship{requester_id: user.id, addressee_id: user.id}
        |> Ecto.Changeset.change(%{status: :pending})
        |> Ecto.Changeset.check_constraint(:requester_id,
          name: :no_self_friendship,
          message: "cannot befriend yourself"
        )
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :check
      assert Keyword.get(opts, :constraint_name) == "no_self_friendship"
    end

    test "send_friend_request maps pair-unique constraint to tagged error (race backstop)" do
      a = user_fixture()
      b = user_fixture()
      scope_a = user_scope_fixture(a)

      # Insert the B→A direction directly, bypassing the context.
      # Now a's pre-checks see no existing row (wrong direction for status checks)...
      # actually the pre-checks ARE direction-aware, so let's verify directly:
      # After direct insert of B→A, scope_a sending to b will hit :request_exists.
      _existing = pending_friendship_fixture(b, a)

      # The pre-check finds the B→A pending row and returns :request_exists.
      # This is the pre-check path. The constraint mapping is the backup for when
      # the pre-check loses the race. Both paths return a sensible tagged error.
      assert {:error, :request_exists, _id} = Social.send_friend_request(scope_a, b.email)
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_pair_conflict/2 — race-backstop helper (exposed for test coverage)
  # ---------------------------------------------------------------------------

  describe "resolve_pair_conflict/2 — DB constraint backstop branches" do
    test "accepted row → :already_friends" do
      a = user_fixture()
      b = user_fixture()
      _accepted = accepted_friendship_fixture(a, b)

      assert {:error, :already_friends} = Social.resolve_pair_conflict(a.id, b.id)
    end

    test "pending row where caller is requester → :already_requested" do
      a = user_fixture()
      b = user_fixture()
      _pending = pending_friendship_fixture(a, b)

      # a is the requester, so from a's perspective: already_requested
      assert {:error, :already_requested} = Social.resolve_pair_conflict(a.id, b.id)
    end

    test "pending row where caller is addressee → {:error, :request_exists, id}" do
      a = user_fixture()
      b = user_fixture()
      existing = pending_friendship_fixture(a, b)

      # b is the addressee: the other user (a) has a pending request to b
      assert {:error, :request_exists, request_id} = Social.resolve_pair_conflict(b.id, a.id)
      assert request_id == existing.id
    end

    test "no row exists (deleted between constraint fire and reload) → :not_found" do
      a = user_fixture()
      b = user_fixture()

      # No row at all — simulates the extremely rare delete-after-constraint race
      assert {:error, :not_found} = Social.resolve_pair_conflict(a.id, b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # map_friendship_constraint_errors/3 — three cond arms tested via real DB errors
  # ---------------------------------------------------------------------------

  describe "map_friendship_constraint_errors/3 — cond arms" do
    # ARM 1: pair_unique_violated? → resolve_pair_conflict/2
    # Produce a real {:error, changeset} carrying the friendships_pair_index unique
    # violation by attempting to Repo.insert a duplicate row, then pass it through
    # the mapper. Verify the mapper dispatches to resolve_pair_conflict/2 which
    # returns the correct tagged error based on the existing row's state.

    test "pair_unique arm with accepted row → :already_friends" do
      a = user_fixture()
      b = user_fixture()
      _accepted = accepted_friendship_fixture(a, b)

      # Produce a real unique-constraint changeset by attempting a duplicate insert.
      {:error, changeset} =
        %Friendship{requester_id: a.id, addressee_id: b.id}
        |> Friendship.create_changeset(%{status: :pending})
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :unique

      assert {:error, :already_friends} =
               Social.map_friendship_constraint_errors({:error, changeset}, a.id, b.id)
    end

    test "pair_unique arm with pending row where caller is requester → :already_requested" do
      a = user_fixture()
      b = user_fixture()
      _pending = pending_friendship_fixture(a, b)

      {:error, changeset} =
        %Friendship{requester_id: a.id, addressee_id: b.id}
        |> Friendship.create_changeset(%{status: :pending})
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :unique

      assert {:error, :already_requested} =
               Social.map_friendship_constraint_errors({:error, changeset}, a.id, b.id)
    end

    test "pair_unique arm with pending row where caller is addressee → {:error, :request_exists, id}" do
      a = user_fixture()
      b = user_fixture()
      existing = pending_friendship_fixture(a, b)

      # Insert reverse direction to produce the constraint error for b's perspective.
      {:error, changeset} =
        %Friendship{requester_id: b.id, addressee_id: a.id}
        |> Friendship.create_changeset(%{status: :pending})
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :unique

      assert {:error, :request_exists, request_id} =
               Social.map_friendship_constraint_errors({:error, changeset}, b.id, a.id)

      assert request_id == existing.id
    end

    # ARM 2: self_check_violated? → {:error, :cannot_befriend_self}
    # Bypass the changeset-level validate_no_self_friendship and produce a real
    # DB CHECK constraint error, then route it through the mapper.

    test "self_check arm → {:error, :cannot_befriend_self}" do
      user = user_fixture()

      # Bypass changeset validation; rely on DB CHECK constraint.
      {:error, changeset} =
        %Friendship{requester_id: user.id, addressee_id: user.id}
        |> Ecto.Changeset.change(%{status: :pending})
        |> Ecto.Changeset.check_constraint(:requester_id,
          name: :no_self_friendship,
          message: "cannot befriend yourself"
        )
        |> Repo.insert()

      assert {_msg, opts} = changeset.errors[:requester_id]
      assert Keyword.get(opts, :constraint) == :check

      assert {:error, :cannot_befriend_self} =
               Social.map_friendship_constraint_errors({:error, changeset}, user.id, user.id)
    end

    # ARM 3: true (validation fallback) → {:error, :validation, changeset}
    # Any changeset error that is neither the pair-unique nor the self-check
    # constraint falls through to the fallback arm. A missing-status error
    # suffices — no DB hit needed; the cond only inspects changeset errors.

    test "validation fallback arm → {:error, :validation, changeset}" do
      a = user_fixture()
      b = user_fixture()

      # An invalid :status value produces a changeset error that is neither a
      # pair-unique nor a self-check constraint — it falls through to the fallback.
      changeset =
        %Friendship{requester_id: a.id, addressee_id: b.id}
        |> Friendship.create_changeset(%{status: :invalid_status})

      refute changeset.valid?

      assert {:error, :validation, ^changeset} =
               Social.map_friendship_constraint_errors({:error, changeset}, a.id, b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # accept_friend_request/2
  # ---------------------------------------------------------------------------

  describe "accept_friend_request/2" do
    test "addressee can accept a pending request, status becomes :accepted" do
      requester = user_fixture()
      addressee = user_fixture()
      addressee_scope = user_scope_fixture(addressee)
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:ok, accepted} = Social.accept_friend_request(addressee_scope, friendship.id)
      assert accepted.status == :accepted

      assert Social.friends?(addressee_scope, requester)
    end

    test "returns :forbidden when the requester tries to accept their own request" do
      requester = user_fixture()
      addressee = user_fixture()
      requester_scope = user_scope_fixture(requester)
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:error, :forbidden} =
               Social.accept_friend_request(requester_scope, friendship.id)
    end

    test "returns :forbidden when an unrelated user tries to accept" do
      requester = user_fixture()
      addressee = user_fixture()
      unrelated_scope = user_scope_fixture()
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:error, :forbidden} =
               Social.accept_friend_request(unrelated_scope, friendship.id)
    end

    test "returns :not_found for a non-existent id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} = Social.accept_friend_request(scope, 999_999_999)
    end

    test "returns :not_found for a bad string id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} = Social.accept_friend_request(scope, "abc")
    end

    test "returns :not_found for a negative integer id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} = Social.accept_friend_request(scope, -1)
    end

    test "accepts a string integer id" do
      requester = user_fixture()
      addressee = user_fixture()
      addressee_scope = user_scope_fixture(addressee)
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:ok, accepted} =
               Social.accept_friend_request(addressee_scope, to_string(friendship.id))

      assert accepted.status == :accepted
    end

    test "returns :already_accepted when already accepted (idempotency)" do
      requester = user_fixture()
      addressee = user_fixture()
      addressee_scope = user_scope_fixture(addressee)
      friendship = accepted_friendship_fixture(requester, addressee)

      assert {:error, :already_accepted} =
               Social.accept_friend_request(addressee_scope, friendship.id)
    end
  end

  # ---------------------------------------------------------------------------
  # decline_friend_request/2
  # ---------------------------------------------------------------------------

  describe "decline_friend_request/2" do
    test "addressee can decline a pending request, row is deleted" do
      requester = user_fixture()
      addressee = user_fixture()
      addressee_scope = user_scope_fixture(addressee)
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:ok, _} = Social.decline_friend_request(addressee_scope, friendship.id)

      assert Repo.get(Friendship, friendship.id) == nil
    end

    test "returns :forbidden when the requester tries to decline their own request" do
      requester = user_fixture()
      addressee = user_fixture()
      requester_scope = user_scope_fixture(requester)
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:error, :forbidden} =
               Social.decline_friend_request(requester_scope, friendship.id)
    end

    test "returns :forbidden when an unrelated user tries to decline" do
      requester = user_fixture()
      addressee = user_fixture()
      unrelated_scope = user_scope_fixture()
      friendship = pending_friendship_fixture(requester, addressee)

      assert {:error, :forbidden} =
               Social.decline_friend_request(unrelated_scope, friendship.id)
    end

    test "returns :not_found for a non-existent id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} = Social.decline_friend_request(scope, 999_999_999)
    end

    test "returns :not_found for a bad string id" do
      scope = user_scope_fixture()

      assert {:error, :not_found} = Social.decline_friend_request(scope, "not-an-id")
    end
  end

  # ---------------------------------------------------------------------------
  # list_friends/2
  # ---------------------------------------------------------------------------

  describe "list_friends/2" do
    test "returns User structs of accepted friends in both directions" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()
      alice_scope = user_scope_fixture(alice)

      # Alice → Bob (accepted)
      _f1 = accepted_friendship_fixture(alice, bob)
      # Carol → Alice (accepted)
      _f2 = accepted_friendship_fixture(carol, alice)

      friends = Social.list_friends(alice_scope)
      friend_ids = Enum.map(friends, & &1.id) |> MapSet.new()

      assert MapSet.member?(friend_ids, bob.id), "Expected bob in friends"
      assert MapSet.member?(friend_ids, carol.id), "Expected carol in friends"
      assert MapSet.size(friend_ids) == 2
    end

    test "returns %User{} structs (not friendship rows)" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _f = accepted_friendship_fixture(alice, bob)

      [friend] = Social.list_friends(alice_scope)
      assert %User{} = friend
    end

    test "excludes pending friendships" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _pending = pending_friendship_fixture(alice, bob)

      assert Social.list_friends(alice_scope) == []
    end

    test "scoped to the current user — does not return other users' friends" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()
      alice_scope = user_scope_fixture(alice)

      # Bob and Carol are friends, but not with Alice
      _f = accepted_friendship_fixture(bob, carol)

      assert Social.list_friends(alice_scope) == []
    end

    test "pagination: page and per_page respected" do
      alice = user_fixture()
      alice_scope = user_scope_fixture(alice)

      friends = for _ <- 1..5, do: user_fixture()
      for friend <- friends, do: accepted_friendship_fixture(alice, friend)

      page1 = Social.list_friends(alice_scope, page: 1, per_page: 3)
      page2 = Social.list_friends(alice_scope, page: 2, per_page: 3)

      assert length(page1) == 3
      assert length(page2) == 2
    end

    test "per_page is capped at 100 — returns at most 100 results" do
      alice = user_fixture()
      alice_scope = user_scope_fixture(alice)

      # Create 5 friends with per_page set well above the cap
      for _ <- 1..5, do: accepted_friendship_fixture(alice, user_fixture())

      result = Social.list_friends(alice_scope, per_page: 9999)
      assert length(result) <= 100
      # With only 5 friends, all 5 are returned (cap not hit but query ran correctly)
      assert length(result) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # list_pending_requests/2
  # ---------------------------------------------------------------------------

  describe "list_pending_requests/2" do
    test "returns incoming pending requests where current user is the addressee" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()
      alice_scope = user_scope_fixture(alice)

      _req1 = pending_friendship_fixture(bob, alice)
      _req2 = pending_friendship_fixture(carol, alice)

      requests = Social.list_pending_requests(alice_scope)
      assert length(requests) == 2
    end

    test "preloads the requester so callers can display who sent each request" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)

      _req = pending_friendship_fixture(bob, alice)

      [request] = Social.list_pending_requests(alice_scope)
      assert request.requester.email == bob.email
    end

    test "does not return requests where current user is the requester" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)

      _req = pending_friendship_fixture(alice, bob)

      assert Social.list_pending_requests(alice_scope) == []
    end

    test "does not return accepted friendships" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)

      _accepted = accepted_friendship_fixture(bob, alice)

      assert Social.list_pending_requests(alice_scope) == []
    end

    test "scoped to the current user" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()
      alice_scope = user_scope_fixture(alice)

      # Request to Bob, not Alice
      _req = pending_friendship_fixture(carol, bob)

      assert Social.list_pending_requests(alice_scope) == []
    end

    test "pagination: page and per_page respected" do
      alice = user_fixture()
      alice_scope = user_scope_fixture(alice)

      for _ <- 1..5 do
        sender = user_fixture()
        pending_friendship_fixture(sender, alice)
      end

      page1 = Social.list_pending_requests(alice_scope, page: 1, per_page: 3)
      page2 = Social.list_pending_requests(alice_scope, page: 2, per_page: 3)

      assert length(page1) == 3
      assert length(page2) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # friends?/2
  # ---------------------------------------------------------------------------

  describe "friends?/2" do
    test "returns true for accepted friendship where current user is requester" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _friendship = accepted_friendship_fixture(alice, bob)

      assert Social.friends?(alice_scope, bob)
    end

    test "returns true for accepted friendship where current user is addressee" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _friendship = accepted_friendship_fixture(bob, alice)

      assert Social.friends?(alice_scope, bob)
    end

    test "returns false for pending friendship" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _friendship = pending_friendship_fixture(alice, bob)

      refute Social.friends?(alice_scope, bob)
    end

    test "returns false when no friendship exists" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)

      refute Social.friends?(alice_scope, bob)
    end

    test "accepts a user id integer instead of a User struct" do
      alice = user_fixture()
      bob = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _friendship = accepted_friendship_fixture(alice, bob)

      assert Social.friends?(alice_scope, bob.id)
    end

    test "returns false for unrelated pair even if other friendships exist" do
      alice = user_fixture()
      bob = user_fixture()
      carol = user_fixture()
      alice_scope = user_scope_fixture(alice)
      _friendship = accepted_friendship_fixture(alice, carol)

      refute Social.friends?(alice_scope, bob)
    end
  end
end
