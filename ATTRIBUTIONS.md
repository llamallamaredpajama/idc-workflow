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
| `runtime/pi/scripts/coms-net-server.ts` | `scripts/coms-net-server.ts` | coms-net Bun HTTP/SSE hub (server) |
| `runtime/pi/extensions/idc-role-harness.ts` | `extensions/idc-role-harness.ts` | per-role guardrails + **glass-wall ACL** (IDC-local) |
| `runtime/pi/extensions/guard-shell-core.ts` | `extensions/guard-shell-core.ts` | shared bash/path/secret guard core |

The glass-wall directional ACL on the `coms_net_send` seam (in `idc-role-harness.ts`, marked
`IDC-LOCAL`) is original IDC work layered onto the vendored guard machinery; it carries no
separate upstream license.
