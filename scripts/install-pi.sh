#!/bin/bash
# install-pi.sh — wire the vendored IDC Pi runtime (runtime/pi/) onto PATH and report
# host compatibility. Sibling of install-codex.sh; the Pi counterpart of the Codex adapter
# installer. The Pi *agent* itself (the `pi` binary, npm pkg @earendil-works/pi-coding-agent —
# historically @mariozechner/pi-*) is an INSTALL-TIME dependency the user installs separately;
# this script vendors and links the IDC runtime SOURCE, never the agent binary.
#
# Usage:
#   install-pi.sh --check                 dry-run: detect Bun + Pi presence/version, report,
#                                         and verify the vendored runtime — mutates NOTHING.
#   install-pi.sh <plugin_root>           link the vendored launcher (idc-pi) into ~/.local/bin
#                                         (idempotent); records state for --revert.
#   install-pi.sh --revert                remove exactly the link(s) this installer created.
#
# Compatibility posture (fail-closed): --check exits non-zero when a HARD prerequisite is
# missing (Bun absent, or the vendored runtime is incomplete) — you cannot boot the coms-net
# hub or the role harness without those. A merely-absent Pi agent is reported as a WARN
# (install it to actually run roles) but does not fail --check.
#
# ${CLAUDE_PLUGIN_ROOT} is NOT a shell env var in the Claude harness (it is text-substituted
# in command bodies only), so the install form MUST pass the plugin root as $1, e.g.
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-pi.sh" "${CLAUDE_PLUGIN_ROOT}"
#
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${IDC_PI_INSTALL_PREFIX:-$HOME/.local/bin}"
STATE="$HOME/.agents/.idc-pi-install-state"
LINKS="$HOME/.agents/.idc-pi-install-links"

# The vendored launcher this installer links onto PATH.
LAUNCHER_NAME="idc-pi"
runtime_dir() { printf '%s/runtime/pi\n' "$1"; }

# The vendored runtime that must exist for the IDC Pi runtime to boot — i.e. the harness files
# `idc-pi run <role>` loads (the `-e` extensions + the `--append-system-prompt` role prompts)
# plus the coms-net hub and license. This is a hand-maintained completeness checklist over the
# in-repo tree, kept in step with build_role_argv() in runtime/pi/scripts/idc-pi.
# tests/smoke/phase8-pi-launchable.sh independently drives the REAL launcher (`run --dry-run`)
# and asserts every path it emits exists in the vendored tree — that is the authoritative
# "fresh clone can boot" check; this list is the fail-closed signal in `--check`.
# (The `pi` agent binary and the role `--skill` packages are operator-provided install-time
# deps that live OUTSIDE the harness tree and are intentionally not listed here.)
runtime_required() {
  local root="$1" rt
  rt="$(runtime_dir "$root")"
  printf '%s\n' \
    "$rt/scripts/idc-pi" \
    "$rt/scripts/coms-net-server.ts" \
    "$rt/extensions/coms-net.ts" \
    "$rt/extensions/minimal.ts" \
    "$rt/extensions/theme-cycler.ts" \
    "$rt/extensions/idc-role-harness.ts" \
    "$rt/extensions/guard-shell-core.ts" \
    "$rt/.pi/agents/idc/think.md" \
    "$rt/.pi/agents/idc/plan.md" \
    "$rt/.pi/agents/idc/sequence.md" \
    "$rt/.pi/agents/idc/ripple.md" \
    "$rt/.pi/agents/idc/build-implementer.md" \
    "$rt/.pi/agents/idc/build-reviewer.md" \
    "$rt/.pi/agents/idc/build-finisher.md" \
    "$rt/LICENSE-pi-harnesses"
}

# ── detection helpers (read-only) ────────────────────────────────────────────

detect_bun() {  # echoes "present <version>" | "absent"
  if command -v bun >/dev/null 2>&1; then
    printf 'present %s\n' "$(bun --version 2>/dev/null | head -1 | tr -d '\r')"
  else
    printf 'absent\n'
  fi
}

detect_pi() {  # echoes "present <version> <scope>" | "absent"
  local ver scope=""
  if command -v pi >/dev/null 2>&1; then
    ver="$(pi --version 2>/dev/null | head -1 | tr -d '\r')"
    [ -n "$ver" ] || ver="unknown"
    # Best-effort scope detection (the pkg was renamed @mariozechner -> @earendil-works).
    local root
    root="$(npm root -g 2>/dev/null || true)"
    if [ -n "$root" ] && [ -d "$root/@earendil-works/pi-coding-agent" ]; then
      scope="@earendil-works/pi-coding-agent"
    elif [ -n "$root" ] && [ -d "$root/@mariozechner/pi-coding-agent" ]; then
      scope="@mariozechner/pi-coding-agent"
    fi
    printf 'present %s %s\n' "$ver" "$scope"
  else
    printf 'absent\n'
  fi
}

# ── --check (dry-run health probe; mutates nothing) ──────────────────────────

do_check() {
  local root="$DEFAULT_PLUGIN_ROOT"
  local hard_fail=0

  echo "install-pi --check (read-only; no changes made)"
  echo "------------------------------------------------"

  local bun_info bun_state
  bun_info="$(detect_bun)"
  bun_state="${bun_info%% *}"
  if [ "$bun_state" = "present" ]; then
    echo "  Bun           PRESENT  ${bun_info#present }"
  else
    echo "  Bun           ABSENT   (required — install from https://bun.sh)"
    hard_fail=1
  fi

  local pi_info pi_state
  pi_info="$(detect_pi)"
  pi_state="${pi_info%% *}"
  if [ "$pi_state" = "present" ]; then
    local rest ver scope
    rest="${pi_info#present }"; ver="${rest%% *}"; scope="${rest#* }"
    [ "$scope" = "$rest" ] && scope=""
    echo "  Pi agent      PRESENT  ${ver}${scope:+  ($scope)}"
  else
    echo "  Pi agent      ABSENT   (install-time dep — install the pi coding agent to run roles)"
  fi

  # Vendored runtime completeness (hard prerequisite).
  local missing=0 f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ ! -f "$f" ]; then
      echo "  runtime/pi    MISSING  ${f#"$root"/}"
      missing=$((missing + 1))
    fi
  done <<EOF
$(runtime_required "$root")
EOF
  if [ "$missing" -eq 0 ]; then
    echo "  runtime/pi    OK       vendored coms-net hub + role harness + license present"
  else
    echo "  runtime/pi    INCOMPLETE ($missing file(s) missing)"
    hard_fail=1
  fi

  echo "------------------------------------------------"
  if [ "$hard_fail" -ne 0 ]; then
    echo "install-pi --check: INCOMPATIBLE (fail-closed) — resolve the hard prerequisites above."
    return 1
  fi
  echo "install-pi --check: OK — host can boot the vendored Pi runtime."
  return 0
}

# ── install / revert (symlink the vendored launcher onto PATH) ───────────────

do_install() {
  local root="$1"
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "install-pi: ERROR plugin root '${root:-}' is not a directory." >&2
    exit 2
  fi
  root="$(cd "$root" && pwd)" || { echo "install-pi: ERROR cannot resolve plugin root." >&2; exit 2; }

  local launcher rt
  rt="$(runtime_dir "$root")"
  launcher="$rt/scripts/$LAUNCHER_NAME"
  if [ ! -f "$launcher" ]; then
    echo "install-pi: ERROR vendored launcher missing: $launcher" >&2
    echo "install-pi: the plugin's runtime/pi/ is incomplete — re-pull the plugin." >&2
    exit 1
  fi

  mkdir -p "$PREFIX" "$(dirname "$STATE")"
  local dest="$PREFIX/$LAUNCHER_NAME"

  # Never clobber a real file we did not create.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "install-pi: ERROR $dest exists and is not a symlink — refusing to overwrite." >&2
    echo "install-pi: move it aside, then re-run." >&2
    exit 2
  fi

  # Record state ONCE (for revert): absent vs a pre-existing symlink we re-point.
  if [ ! -f "$STATE" ]; then
    if [ -L "$dest" ]; then
      printf 'PREFIX=%s\nORIGINAL=symlink\nORIGINAL_TARGET=%s\n' "$PREFIX" "$(readlink "$dest")" > "$STATE"
    else
      printf 'PREFIX=%s\nORIGINAL=absent\n' "$PREFIX" > "$STATE"
    fi
  fi

  rm -f "$dest"
  ln -s "$launcher" "$dest" || { echo "install-pi: ERROR failed to link $dest" >&2; exit 1; }
  printf '%s\n' "$LAUNCHER_NAME" > "$LINKS"

  if [ ! -L "$dest" ] || [ "$(readlink "$dest")" != "$launcher" ]; then
    echo "install-pi: ERROR link verification failed for $dest." >&2
    exit 1
  fi
  echo "install-pi: linked $dest -> $launcher"
  case ":$PATH:" in
    *":$PREFIX:"*) : ;;
    *) echo "install-pi: NOTE $PREFIX is not on PATH — add it: export PATH=\"$PREFIX:\$PATH\"" ;;
  esac
  echo "install-pi: run 'install-pi.sh --revert' to remove the link."
}

do_revert() {
  if [ ! -f "$STATE" ]; then
    echo "install-pi: no install state at $STATE — nothing to revert."
    return 0
  fi
  local prefix original target dest
  prefix="$(grep '^PREFIX=' "$STATE" | cut -d= -f2-)"
  original="$(grep '^ORIGINAL=' "$STATE" | cut -d= -f2-)"
  target="$(grep '^ORIGINAL_TARGET=' "$STATE" | cut -d= -f2- || true)"
  dest="${prefix:-$PREFIX}/$LAUNCHER_NAME"

  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "install-pi: ERROR $dest is now a real file (not our symlink) — refusing to delete it." >&2
    echo "install-pi: inspect it, then rm -f '$STATE' '$LINKS'." >&2
    exit 2
  fi

  rm -f "$dest"  # removes only the symlink, never data behind it
  case "$original" in
    symlink) [ -n "$target" ] && ln -s "$target" "$dest" && echo "install-pi: reverted — restored $dest -> $target" ;;
    absent)  echo "install-pi: reverted — removed $dest (was absent before install)" ;;
    *)       echo "install-pi: reverted — removed $dest" ;;
  esac
  rm -f "$STATE" "$LINKS"
  return 0
}

case "${1:-}" in
  --check)  do_check ;;
  --revert) do_revert ;;
  "")
    echo "usage: install-pi.sh --check | <plugin_root> | --revert" >&2
    exit 2 ;;
  *)        do_install "$1" ;;
esac
