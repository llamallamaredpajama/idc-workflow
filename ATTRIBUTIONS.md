# Attributions

Third-party source vendored into this plugin, with upstream provenance and license.

## pi-harnesses — Pi runtime (`runtime/pi/`)

The IDC Pi runtime is **vendored source** from the `pi-harnesses` project (the Pi Coding
Agent extension playground). Only the IDC-relevant runtime is vendored — not the full
extension set. The Pi *agent* itself (the `pi` binary / npm package
`@earendil-works/pi-coding-agent`, historically `@mariozechner/pi-*`) is **not** bundled; it
is an install-time dependency installed separately.

- **Upstream:** pi-harnesses (© 2026 IndyDevDan)
- **License:** MIT — preserved verbatim at [`runtime/pi/LICENSE-pi-harnesses`](runtime/pi/LICENSE-pi-harnesses) (no-edit)
- **Each vendored file** carries a top-of-file attribution header citing its upstream path.
  IDC-local additions are marked with an `IDC-LOCAL` banner comment.

Vendored files:

| Vendored path | Upstream path | Role |
|---|---|---|
| `runtime/pi/scripts/coms-net-server.ts` | `scripts/coms-net-server.ts` | coms-net Bun HTTP/SSE hub (server; **glass-wall ACL enforced server-side**, IDC-local) |
| `runtime/pi/scripts/idc-pi` | `scripts/idc-pi` | role launcher (reference source) |
| `runtime/pi/extensions/coms-net.ts` | `extensions/coms-net.ts` | coms-net client + `coms_net_send` seam (**glass-wall ACL wired**, IDC-local) |
| `runtime/pi/extensions/idc-role-harness.ts` | `extensions/idc-role-harness.ts` | per-role guardrails + **glass-wall directional ACL** (IDC-local) |
| `runtime/pi/extensions/guard-shell-core.ts` | `extensions/guard-shell-core.ts` | shared bash/path/secret guard core |
| `runtime/pi/extensions/review-orchestrator.ts` | `extensions/review-orchestrator.ts` | review orchestration command |
| `runtime/pi/extensions/review-orchestrator-core.ts` | `extensions/review-orchestrator-core.ts` | review orchestration core helpers |
| `runtime/pi/extensions/themeMap.ts` | `extensions/themeMap.ts` | shared theme defaults (transitive dep) |
| `runtime/pi/extensions/minimal.ts` | `extensions/minimal.ts` | compact footer extension (`-e` launch dep) |
| `runtime/pi/extensions/theme-cycler.ts` | `extensions/theme-cycler.ts` | theme-cycler extension (`-e` launch dep) |
| `runtime/pi/.pi/agents/idc/*.md` | `.pi/agents/idc/*.md` | role system prompts loaded by `idc-pi run` (7 files, byte-faithful) |

### IDC-local additions (not upstream)

- **Glass-wall directional ACL** on the `coms_net_send` seam — `evaluateComsNetSendForRole` /
  `resolveComsNetPeerRole` in `idc-role-harness.ts`, enforced in `coms-net.ts` before any
  network send **and authoritatively re-enforced in `coms-net-server.ts` (`handleSendMessage`)
  before any message is queued**, so a direct POST to `/v1/messages` cannot bypass the wall
  (the hub imports the same pure decision — single source of truth). A role resident may message
  only peers strictly downstream in the IDC river
  (think → plan → sequence → build-impl → build-review → build-finish) plus the Ripple sink;
  upstream/unknown sends are denied fail-closed and logged to the `coms-net-log` channel.
  This is original IDC work layered onto the vendored guard machinery; no separate upstream
  license applies.

The launcher (`runtime/pi/scripts/idc-pi`) is vendored as **reference source**; wiring the
full multi-role orchestration onto a host is the concern of the Pi adapter (unit B2).
