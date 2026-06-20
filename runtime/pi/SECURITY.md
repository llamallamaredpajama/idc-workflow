# Pi coms-net runtime — trust model & security posture

This is an honest statement of what the coms-net hub's access controls **do and do not**
guarantee, so they aren't mistaken for adversarial multi-tenant authorization.

## Deployment shape (the trust boundary)

The coms-net hub is a **local, loopback, single-OS-user** fabric:

- It binds `127.0.0.1` by default and **refuses to bind a non-loopback address without an explicit
  token** (`coms-net-server.ts`). It is not meant to be exposed on a network.
- All role residents in a project are launched by **one trusted `idc-pi` process** and share **one
  project bearer token**, distributed via a `0600 server.secret.json` file that residents read.
- Therefore the **bearer token's trust boundary is the OS user account.** Any process running as
  the same user can read that `0600` file and obtain full hub control. Every role resident also has
  the `bash` tool, so it can already reach the hub directly.

Under this model, an "attacker who holds the bearer" is **already a trusted resident or a same-user
process that owns everything the residents own.** The controls below are therefore aimed at
*cooperating residents* and *prompt-injection / casual-misuse* resistance — **not** at defending
against a fully-malicious same-user process.

## What the controls guarantee

| Control | Guarantee | Code |
|---|---|---|
| **Glass-wall directional ACL** (client + hub) | A role resident may message only peers strictly downstream in the IDC river (+ the Recirculator). Enforced on the hub before queue/deliver, off the launcher-proven role — not a self-asserted name. | `evaluateComsNetSendForRole`, `handleSendMessage` |
| **Per-session token** | Every session-scoped endpoint (send, SSE `/v1/events`, response submit, get, await, heartbeat, delete) requires the session's own token (`x-coms-session-token`), issued at registration and `timingSafeEqual`-compared. One resident cannot hijack another's stream, forge its reply, poll its messages, forge its liveness, or unregister it. | `sessionAuthorized` |
| **Per-role registration capability** (`idc-pi fleet` mode only) | Registering an IDC role requires `x-coms-role-cap = HMAC(K, role)`, where `K` is a hub master key the **fleet supervisor** holds in memory and hands each resident **only its own** role's cap (env-only, never a file). A resident cannot *mint* a role it wasn't launched as. The ACL runs off the proven `canonical_role`. **In pane mode the hub is unconfigured** and this control is off (see below). | `roleCap`, `handleRegister`, `command_fleet` |

These together make role identity and per-session actions **launcher-proven**, so workflow
integrity (the river order, the glass wall) holds even if a resident's LLM is prompt-injected into
trying to message upstream or impersonate a peer.

## What they do NOT guarantee (documented residual)

- **Not a boundary against a fully-malicious same-OS-user process.** No secret given to the hub is
  provably unreachable by another same-user process. The bearer is in a `0600` file (readable). The
  role caps and master key are kept in **env only** (a sibling cannot read another process's env —
  verified on macOS — and `task_for_pid` is restricted for same-user non-root, making memory
  inspection hard but not impossible). So the HMAC capability **raises the bar** (a prompt-injected
  `build-impl` resident has only the `build-impl` cap and cannot forge `think`'s) — it is
  **defense-in-depth, not an absolute authorization boundary** on a shared user account.
- If you ever expose the hub beyond loopback, you must supply an explicit
  `PI_COMS_NET_AUTH_TOKEN` (the launcher passes it through) and re-evaluate this model — it was
  designed for loopback.

### The per-role command guard is best-effort (a static analyzer, not a sandbox)

The per-role file-write/bash guard (`idc-role-harness.ts` + `guard-shell-core.ts`) is a **static
command analyzer**. It reliably blocks the *detected* mutating surface — direct file writes outside a
role's authority, the secret denylist, `git` worktree/history mutations (path-checked, force-push and
cross-repo `-C`/`--git-dir`/`--work-tree` denied), `gh` tracker/PR writes by role, dangerous `gh`
verbs, glob/`--pathspec-from-file` refusals, and the `git -c alias=…` arbitrary-shell evasion. But
because it reasons over a *modeled* shell grammar, a sufficiently exotic construct is always
conceivable, and two known residuals stand within this same best-effort envelope:

- **Interpreter payloads.** A read-only role (e.g. `build-review`) can still write a file via an
  interpreter whose body the static analyzer cannot enumerate — `python3 - <<EOF … open(…,"w") … EOF`,
  `node -e`, perl/ruby writers. The guard sees no modeled mutation and allows the command.
- **Read-only cross-repo git.** The cross-repo `-C`/`--git-dir`/`--work-tree` block fires on git
  *mutations*; a pure read (`git -C /other status`) reaches another repo because reads skip the
  mutation path.

Both are consistent with the loopback / single-OS-user model: the resident already runs as a user who
can do these things directly, so this guard is **prompt-injection / casual-misuse resistance, not a
sandbox** — exactly as the coms-net controls above. Closing them would require interpreter-payload
enumeration (an unbounded whack-a-mole the `git -c alias` case already proves a static analyzer cannot
win) rather than a real OS sandbox; it is intentionally **not** chased. The merge gate is likewise
**behavioral** (the finisher prompt's merge-only-on-green/PASS contract, mirroring the Claude runtime),
not a hard guard interlock.

## Two launch modes (where the role-cap boundary actually holds)

The role-cap boundary requires the master key `K` to reach the hub and each resident over a channel
that is **both secret and shared** — which only one launch mode provides:

- **`idc-pi fleet` — the SECURE supervised mode (role-cap ENFORCED).** A small **bun supervisor**
  (`runtime/pi/scripts/fleet-supervisor.ts`) holds `K` in memory and spawns the hub + every resident
  via `Bun.spawn` **execve env maps** — so `K` reaches only the hub, each resident gets only its own
  `HMAC(K, role)` cap (computed in-memory with `node:crypto`), and **neither `K` nor any cap ever
  appears in a process argv / command string** (the earlier bash `env -i VAR=val` + `openssl
  -macopt key:` forms leaked them via `ps`; the launcher passes the secrets to the supervisor as
  shell env *assignments*, not argv, and the spec it hands over is secret-free). `K` never touches
  disk. The fleet also runs the **fail-closed governance preflight** before spawning anything. This
  is the mode where role-minting is actually closed. Tests: `phase8-pi-fleet-secret.sh` proves each
  resident gets only its cap, never `K`, and that **`ps` never shows `K`/caps**; the governance gate
  test covers `idc-pi fleet` with a drifted sidecar. Test seam: `PI_IDC_RESIDENT_BIN` (fake resident).
- **`idc-pi open` / `open-all` / `open-cmux` / iTerm — the dev/inspect pane mode (role-cap OFF).**
  Each pane is a separate `env -i` invocation launched via a `ps`-visible command string. There is
  **no channel through cmux panes that is both secret and cross-pane**: filing `K` (like the bearer)
  would make it same-user-readable, and putting `K` in the pane string would leak it via `ps`. So
  the pane mode runs the hub **unconfigured** — role authority falls back to the resolved name and
  role-minting is open (bounded by the OS user, as above). Use it for development/inspection; use
  **`idc-pi fleet`** when you want the enforced boundary.

> Earlier guidance to "export `PI_COMS_NET_ROLE_HMAC_KEY` so server and run share one key" was wrong
> for the pane path (`env -i` strips it; whitelisting it would leak it via `ps`) — superseded by the
> two modes above.
