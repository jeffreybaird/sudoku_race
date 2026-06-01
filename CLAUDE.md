# CLAUDE.md — Sudoku Race

Claude Code read this every session. Follow all rules no exception unless user override for specific task.

## Project Overview

Small Elixir / Phoenix 1.8 / LiveView app. Two-to-handful-of-users toy: pick a sudoku puzzle from a seeded pool, solve it timed, see your friend's time when they've solved the same one.

**This is a personal app.** Do not over-engineer. Boring Phoenix defaults are correct.

### Architecture Summary

- **Single Postgres DB**, standard `Ecto.Repo`.
- **Auth:** Built on `mix phx.gen.auth` primitives (session tokens, bcrypt, scopes) but configured for **password-first registration**: register with email + password (+ optional `username`), logged in immediately, no email confirmation and **no magic link** (magic-link login was removed — it also eliminated the unconfirmed-user-with-password session-fixation footgun). Email is still the login identifier and the friend-lookup key. Don't reintroduce magic link or roll bespoke auth; keep using the gen.auth primitives.
- **Real-time:** Phoenix PubSub for "friend solved a puzzle" notifications. One topic per user: `user:{user_id}:activity`.
- **Puzzle pool:** Seeded from a public dataset at deploy time. Each puzzle has a clue grid, solution grid, and difficulty rating.
- **Deployment:** DigitalOcean droplet, Docker Compose (web + Postgres on same host), Caddy reverse proxy.
- **Mobile + desktop responsive.** Input model auto-detected (touch → tap-cell-then-tap-number, pointer → click-cell-then-type), with user override persisted in profile.

### Erlang/OTP Version Policy

Dev host runs OTP 29. Build, CI, and production pin **OTP 28** — no official Elixir 1.19.5 + OTP 29 image exists on Docker Hub. This dev-vs-image skew is intentional: Phoenix releases bundle ERTS from the build image, so production always runs OTP 28 consistently.

The Dockerfile pins the newest OTP 28 **patch that hexpm/elixir publishes for linux/amd64** (currently `28.4.3` — `hexpm/elixir:1.19.5-erlang-28.4.3-debian-bookworm-20260518-slim`). The very latest patches land arm64-first; pinning an arm64-only tag (e.g. `28.5.0.1`) breaks the amd64 CI build with `no match for platform in manifest`. Keep the OTP **major** at 28; bump the patch only to track amd64 availability, and verify the chosen tag is multi-arch before changing it. Revisit the major only when Elixir is upgraded to a version that has an official OTP 29 image.

### Context Modules

Business logic lives in context modules. LiveViews + controllers never call `Repo` direct.

| Context     | Responsibility                                            |
|-------------|-----------------------------------------------------------|
| `Accounts`  | Users, sessions, registration, email confirmation         |
| `Social`    | Friend requests, friendships, activity feed               |
| `Puzzles`   | Puzzle pool, lookup, difficulty filters                   |
| `Attempts`  | Puzzle attempts, timing, completion, validation           |

Keep it to these four until a real need justifies a fifth.

---

## Architecture Principles

### 1. Contexts Are the Public API

All DB access through context modules. LiveViews + controllers never call `Repo` direct.

### 2. Tagged Tuple Errors

All fallible functions return specific, serializable tagged tuples:

```elixir
{:ok, resource}
{:error, :validation, changeset}
{:error, :not_found}
{:error, :forbidden}
{:error, :already_friends}
{:error, :already_attempted}
```

Never return bare `{:error, changeset}`. Never return string error messages from context functions.

### 3. Single Responsibility — One Function, One Job

Every function does one thing. If write `and` in `@doc`, function needs split.

### 4. Pipe-First Data Transformation

Multi-step transformations use `|>`. Data flows top→bottom. Exception: value used more than once, or naming improves readability.

### 5. Private Functions Are Prefixed with Intent

```elixir
defp reject_completed_attempts(attempts)  # ✅
defp filter_attempts(attempts)             # ❌
```

### 6. Pagination on Every List Query

Every context function returning a list accepts `opts \\ []` with `page` + `per_page`. Even if no UI paginates today. Max `per_page` = 100.

### 7. Validate Solutions Server-Side

Never trust the client. When an attempt is submitted, the server compares the submitted grid to the stored solution. Timer end-time is set server-side on submission.

### 8. PubSub Only for Cross-User Notifications

PubSub is justified for "your friend just solved a puzzle." Do NOT PubSub timer ticks, cell entries, or any per-attempt state. Timer runs client-side; only completion crosses the wire.

---

## Code Style Rules

### **EVERY CODE CHANGE THAT ADDS BEHAVIOR MUST BE ACCOMPANIED BY A TEST THAT VALIDATES SAID BEHAVIOR**

### Doctests on Every Public Function

Every public function (`def`, not `defp`) must have `@doc` block with at least one doctest for happy path.

Exempt: functions that hit DB or external services — use unit tests with mocks/factories.

### Test Categories Required

- **Context tests** (`test/sudoku/`) — every public context function. Cover happy + failure paths.
- **LiveView tests** (`test/sudoku_web/live/`) — render + interaction for every LiveView.
- **Auth flows** — registration, confirmation, login, logout covered.

### Frontend

- No business logic in JS hooks — hooks = thin DOM/JS bridges (timer tick, keyboard input routing).
- `data-test` attributes for test selectors, not CSS classes.
- No `phx-click` on `<div>` or `<span>` — use `<button>` or `<a>`.

---

## Accessibility — WCAG 2.1 AA

Apply to every UI add or mod:

1. **Semantic HTML over ARIA.** Use `<button>`, `<a>`, `<nav>`, `<main>`.
2. **Keyboard navigable.** Sudoku grid must support arrow-key navigation between cells, number keys for entry, Backspace/Delete to clear. No keyboard trap.
3. **Visible focus indicators** on every interactive element, including the active grid cell.
4. **ARIA labels on icon-only controls.** Each cell should have an `aria-label` describing position and current value.
5. **Color contrast** — text ≥ 4.5:1. Don't convey errors by color alone (use icon + color).
6. **Forms** — every input linked to `<label>`. Errors linked via `aria-describedby`.
7. **Touch targets** min 44×44 CSS pixels — critical for the mobile number pad.
8. **Dynamic content** — friend-activity notifications use `aria-live="polite"`.

---

## Git Process: Trunk-Based & Atomic Commits

- Work off `main`. Short-lived branches OK for larger features.
- Atomic commits: one thing per commit, codebase valid at every commit.
- Commit messages: `feat:`, `fix:`, `refactor:`, `test:`, `chore:`. Be specific.
- Before every commit: `mix format`, `mix credo --strict`, `mix test`. No commit if checks fail.
- No `IO.inspect` in committed code.

---

## Tests Are a Contract, Not an Obstacle

1. Never modify an existing test to make it pass — fix the code, not the test.
2. Never weaken an assertion to pass a failing test.
3. Never delete a test to resolve a failure — flag for discussion.
4. New feature causes existing tests to fail → burden of proof on new feature.
5. If you believe an existing test is genuinely wrong, flag it with a comment and ask before changing.

Test suite = ratchet, only moves forward.

---

## What Not to Do

### Code
- No `Repo` calls outside context modules.
- No multi-responsibility functions.
- No public function without doctest (exempt: DB + external service calls).
- No untested branch — every `case`/`cond`/`if` arm needs a test.
- No `IO.inspect` in committed code.
- No string error messages from context functions — use tagged atoms.
- No client-trusted solution validation.
- No client-trusted timer end-time.

### Scope — explicit non-goals
- No groups, no chat. Friendship is one-to-one.
- No PUBLIC leaderboards. A friends-only leaderboard (puzzles your friends solved, with their times) IS allowed — it never exposes a non-friend's data and is scoped to accepted friendships in both directions.
- No puzzle generator. Use the seeded pool.
- No native mobile app. Responsive web only.
- No payments.
- No anti-cheat beyond server-side solution validation.

### Infrastructure
- No secrets in `config/config.exs` or `config/prod.exs` — runtime only via `config/runtime.exs`.
- No deploys that skip tests.
- No `mix` commands in production — Phoenix release commands only.

### Frontend
- No business logic in TypeScript/JS hooks.
- No CSS classes as test selectors — use `data-test`.
- No `phx-click` on `<div>` or `<span>`.
- No interactive element without visible focus indicator.
- No icon-only button without `aria-label`.