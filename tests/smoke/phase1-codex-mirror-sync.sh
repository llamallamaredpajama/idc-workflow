#!/bin/bash
# Phase 1 smoke (issue #6 / MIN-14) — install-codex.sh re-sync prunes STALE mirror links.
#
# install-codex.sh converts ~/.agents/skills into a real directory that mirrors every
# ~/.claude/skills entry plus the IDC plugin adapters. Before the fix, a re-install reset the
# link manifest and re-linked the CURRENT entries but never removed mirror symlinks for skills
# that had since been DELETED — so a removed ~/.claude/skills entry left a dangling symlink in
# the Codex view forever (confirmed live: 33 dangling links survived a re-run). This test proves
# a plain re-install now prunes its own stale links while leaving valid links, the adapters, and
# any REAL (non-symlink) file/dir in the mirror untouched.
#
# SAFETY: every installer invocation runs under an OVERRIDDEN HOME pointing at a throwaway temp
# dir, so the real ~/.agents mirror is never read or mutated. The prune step only ever `rm -f`s
# SYMLINKS — the REAL_* guard entries below prove it can never delete a real file or directory.
#
# Failing-test-first: with no prune pass the deleted skill's dangling mirror link survives the
# re-install, so the prune assertion fails. Adding the prune pass turns it green.
#
# Usage: bash tests/smoke/phase1-codex-mirror-sync.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$PLUGIN/scripts/install-codex.sh"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$INSTALL" ] || fail "install-codex.sh missing at $INSTALL"
[ -d "$PLUGIN/skills/idc-adapter-codex" ] || fail "plugin is missing the Codex adapter (cannot install)"

# Throwaway HOME — the installer reads ~/.agents, ~/.claude/skills from $HOME, so this confines
# every read+write to the sandbox. The real user home is NEVER touched.
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
HOME_SBX="$SBX/home"
AGENTS_SKILLS="$HOME_SBX/.agents/skills"
CLAUDE_SKILLS="$HOME_SBX/.claude/skills"

# A throwaway personal-skills set: one we keep, one we will delete before the re-install.
mkdir -p "$CLAUDE_SKILLS/zz-mirror-keep" "$CLAUDE_SKILLS/zz-mirror-drop"
printf '%s\n' '# keep' > "$CLAUDE_SKILLS/zz-mirror-keep/SKILL.md"
printf '%s\n' '# drop' > "$CLAUDE_SKILLS/zz-mirror-drop/SKILL.md"

run_install() { env HOME="$HOME_SBX" bash "$INSTALL" "$PLUGIN" >"$SBX/install.log" 2>&1; }

# ---- install #1: the mirror is built; both personal skills + the adapter are linked ----------
run_install || { cat "$SBX/install.log"; fail "first install-codex run failed"; }
[ -L "$AGENTS_SKILLS/zz-mirror-keep" ]   || fail "first install did not mirror zz-mirror-keep"
[ -L "$AGENTS_SKILLS/zz-mirror-drop" ]   || fail "first install did not mirror zz-mirror-drop"
[ -e "$AGENTS_SKILLS/zz-mirror-drop" ]   || fail "zz-mirror-drop mirror link does not resolve after first install"
[ -f "$AGENTS_SKILLS/idc-adapter-codex/SKILL.md" ] || fail "first install did not link the Codex adapter"

# ---- plant REAL (non-symlink) entries the prune must NEVER remove ----------------------------
# A plain file and a real directory with content, neither in the link manifest — the symlink-only
# guard means prune must leave both intact even though they are "unknown" to the installer.
printf '%s\n' 'real user data — must survive prune' > "$AGENTS_SKILLS/REAL_GUARD.txt"
mkdir -p "$AGENTS_SKILLS/REAL_DIR_GUARD"
printf '%s\n' 'real dir content' > "$AGENTS_SKILLS/REAL_DIR_GUARD/keep.txt"

# ---- delete a personal skill, then re-install (the re-sync path) ------------------------------
rm -rf "$CLAUDE_SKILLS/zz-mirror-drop"          # now $AGENTS_SKILLS/zz-mirror-drop dangles
run_install || { cat "$SBX/install.log"; fail "re-install (re-sync) run failed"; }

# ---- core assertion: the now-stale/dangling mirror link was PRUNED ---------------------------
if [ -e "$AGENTS_SKILLS/zz-mirror-drop" ] || [ -L "$AGENTS_SKILLS/zz-mirror-drop" ]; then
  fail "stale mirror link zz-mirror-drop survived re-install (prune pass missing or ineffective)"
fi

# ---- valid links + the adapter must survive --------------------------------------------------
[ -L "$AGENTS_SKILLS/zz-mirror-keep" ] || fail "re-install wrongly removed the still-valid zz-mirror-keep link"
[ -e "$AGENTS_SKILLS/zz-mirror-keep" ] || fail "zz-mirror-keep link no longer resolves after re-install"
[ -f "$AGENTS_SKILLS/idc-adapter-codex/SKILL.md" ] || fail "re-install wrongly removed/broke the Codex adapter link"

# ---- safety: prune is symlink-only — real file + real dir are untouched ----------------------
[ -f "$AGENTS_SKILLS/REAL_GUARD.txt" ]            || fail "prune deleted a REAL plain file (symlink-only guard breached!)"
[ -L "$AGENTS_SKILLS/REAL_GUARD.txt" ]            && fail "REAL_GUARD.txt was unexpectedly turned into a symlink"
[ -d "$AGENTS_SKILLS/REAL_DIR_GUARD" ]            || fail "prune deleted a REAL directory (symlink-only guard breached!)"
[ -f "$AGENTS_SKILLS/REAL_DIR_GUARD/keep.txt" ]   || fail "prune emptied a REAL directory's content"

# ---- the kept skill's underlying target was never touched (prune removes links, not data) ----
[ -f "$CLAUDE_SKILLS/zz-mirror-keep/SKILL.md" ]   || fail "re-sync mutated the personal skill behind a kept link"

echo "PASS: install-codex re-sync prunes stale/dangling mirror links; valid links, adapters, and real files survive (HOME-sandboxed — real ~/.agents untouched)"
