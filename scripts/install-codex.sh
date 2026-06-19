#!/bin/bash
# install-codex.sh — wire the IDC Codex adapters into the Codex skill view.
#
# Codex reads personal skills from ~/.agents/skills, which normally ships as a
# SYMLINK to ~/.claude/skills (so every ~/.claude/skills entry auto-loads in Codex).
# Symlinking the IDC plugin's Codex adapters into ~/.claude/skills would pollute every
# Claude project with bare skills, so instead we convert ~/.agents/skills into a REAL
# directory that (a) re-links every existing ~/.claude/skills entry — preserving Codex's
# current view — and (b) links the IDC plugin skills (the single Codex runtime adapter
# idc-adapter-codex + the shared skills) to the installed plugin copy. v2 has one Codex
# adapter over the shared runtime-neutral skills — Codex resolves them by bare name.
#
# Usage:
#   install-codex.sh <plugin_root>   install / refresh adapter links (idempotent)
#   install-codex.sh --revert        restore the original ~/.agents/skills state
#
# Safety posture (load-bearing — keep it this way):
#   - install records the pre-install state ONCE (symlink / realdir / absent) plus the
#     exact link names it creates (the link manifest); a plain FILE at ~/.agents/skills
#     aborts with exit 2 before anything is touched.
#   - revert classifies the CURRENT state BEFORE any removal and only ever deletes
#     symlinks (by recorded name when the manifest exists). It never deletes real files
#     or a directory that still has non-link content — those paths fail loudly
#     (non-zero exit + instructions) instead of "succeeding".
#   - install fails loudly (non-zero) when the plugin root is relative/unresolvable or
#     when fewer than all 5 adapter links resolve to a SKILL.md.
#
# ${CLAUDE_PLUGIN_ROOT} is NOT a shell env var in the Claude harness (it is text-
# substituted in command bodies only), so the caller MUST pass the plugin root as $1,
# e.g.  bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" "${CLAUDE_PLUGIN_ROOT}"
#
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.

set -uo pipefail

AGENTS_DIR="$HOME/.agents"
AGENTS_SKILLS="$AGENTS_DIR/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
STATE="$AGENTS_DIR/.idc-install-state"
LINKS="$AGENTS_DIR/.idc-install-links"

# The IDC plugin skill dirs to link into the Codex skill view (computed from the plugin's
# skills/ in install(); idc-adapter-codex is the load-bearing one). Empty until install().
ADAPTERS=""
REQUIRED_ADAPTER="idc-adapter-codex"

is_adapter() {
  case " $ADAPTERS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# link_one <target> <linkpath> — replace <linkpath> with a symlink to <target>,
# but never clobber a real file/dir we did not create. Records every link it creates
# in the $LINKS manifest so --revert removes exactly ours and nothing else.
# Returns 0 when the link exists afterwards, 1 when it was skipped/failed.
link_one() {
  _target="$1"; _link="$2"
  if [ -e "$_link" ] && [ ! -L "$_link" ]; then
    echo "install-codex: WARN skip $_link (exists and is not a symlink)"
    return 1
  fi
  if [ -L "$_link" ] && [ "$(readlink "$_link")" != "$_target" ]; then
    echo "install-codex: NOTE re-pointing existing symlink $_link -> $_target"
  fi
  rm -f "$_link"
  ln -s "$_target" "$_link" || {
    echo "install-codex: WARN failed to create link $_link"
    return 1
  }
  basename "$_link" >> "$LINKS"
  return 0
}

record_state_once() {
  [ -f "$STATE" ] && return 0
  created_agents_dir=0
  [ -d "$AGENTS_DIR" ] || created_agents_dir=1
  mkdir -p "$AGENTS_DIR"
  if [ -L "$AGENTS_SKILLS" ]; then
    {
      echo "ORIGINAL_KIND=symlink"
      echo "ORIGINAL_TARGET=$(readlink "$AGENTS_SKILLS")"
      echo "AGENTS_DIR_CREATED=$created_agents_dir"
    } > "$STATE"
  elif [ -d "$AGENTS_SKILLS" ]; then
    {
      echo "ORIGINAL_KIND=realdir"
      echo "AGENTS_DIR_CREATED=$created_agents_dir"
    } > "$STATE"
  elif [ -e "$AGENTS_SKILLS" ]; then
    # Backstop (install() also guards): a plain file here is user data — never touch it.
    echo "install-codex: ERROR $AGENTS_SKILLS exists and is a plain file (not a symlink or directory)." >&2
    echo "install-codex: move it aside, then re-run." >&2
    exit 2
  else
    {
      echo "ORIGINAL_KIND=absent"
      echo "AGENTS_DIR_CREATED=$created_agents_dir"
    } > "$STATE"
  fi
}

revert() {
  if [ ! -f "$STATE" ]; then
    echo "install-codex: no install state at $STATE — nothing to revert."
    return 0
  fi
  kind="$(grep '^ORIGINAL_KIND=' "$STATE" | cut -d= -f2-)"
  target="$(grep '^ORIGINAL_TARGET=' "$STATE" | cut -d= -f2- || true)"
  dir_created="$(grep '^AGENTS_DIR_CREATED=' "$STATE" | cut -d= -f2- || true)"

  # Classify the CURRENT state BEFORE any removal — never blanket-delete.
  if [ -L "$AGENTS_SKILLS" ]; then
    current=symlink
  elif [ -d "$AGENTS_SKILLS" ]; then
    current=dir
  elif [ -e "$AGENTS_SKILLS" ]; then
    current=file
  else
    current=absent
  fi

  if [ "$current" = "file" ]; then
    echo "install-codex: ERROR $AGENTS_SKILLS is now a plain file (not the directory this installer created)." >&2
    echo "install-codex: refusing to delete it — restore it manually, then rm -f '$STATE' '$LINKS'." >&2
    exit 2
  fi

  case "$kind" in symlink|realdir|absent) : ;; *)
    echo "install-codex: ERROR unknown recorded state '$kind' in $STATE — refusing to remove anything." >&2
    echo "install-codex: inspect $AGENTS_SKILLS manually, then rm -f '$STATE' '$LINKS'." >&2
    exit 2 ;;
  esac

  removed=0
  if [ "$current" = "dir" ]; then
    # Remove only symlink entries — exactly the recorded ones when the manifest exists.
    if [ -f "$LINKS" ]; then
      while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [ -L "$AGENTS_SKILLS/$name" ]; then
          rm -f "$AGENTS_SKILLS/$name"
          removed=$((removed + 1))
        fi
      done < "$LINKS"
    else
      # Pre-manifest install: fall back to removing all symlink entries (still never
      # touches real files/dirs).
      for entry in "$AGENTS_SKILLS"/*; do
        [ -L "$entry" ] || continue
        rm -f "$entry"
        removed=$((removed + 1))
      done
    fi
    case "$kind" in
      symlink)
        if rmdir "$AGENTS_SKILLS" 2>/dev/null; then
          ln -s "$target" "$AGENTS_SKILLS"
          echo "install-codex: reverted — $AGENTS_SKILLS -> $target (removed $removed link(s))"
        else
          echo "install-codex: ERROR removed $removed link(s) but $AGENTS_SKILLS still has non-link content." >&2
          echo "install-codex: refusing to delete real files. Move the remaining entries aside, then re-run --revert (original symlink target: $target)." >&2
          exit 1
        fi ;;
      absent)
        if rmdir "$AGENTS_SKILLS" 2>/dev/null; then
          echo "install-codex: reverted — removed $AGENTS_SKILLS (was absent before install; removed $removed link(s))"
        else
          echo "install-codex: ERROR removed $removed link(s) but $AGENTS_SKILLS still has non-link content (path was absent before install)." >&2
          echo "install-codex: refusing to delete real files — move them aside and re-run --revert." >&2
          exit 1
        fi ;;
      realdir)
        echo "install-codex: reverted — original was a real directory; removed $removed link(s) we created, kept everything else." ;;
    esac
  elif [ "$current" = "symlink" ]; then
    case "$kind" in
      symlink)
        cur_target="$(readlink "$AGENTS_SKILLS")"
        if [ "$cur_target" = "$target" ]; then
          echo "install-codex: $AGENTS_SKILLS already points at the original target ($target) — nothing to undo."
        else
          rm -f "$AGENTS_SKILLS"  # removes only the symlink itself, never data behind it
          ln -s "$target" "$AGENTS_SKILLS"
          echo "install-codex: reverted — re-pointed $AGENTS_SKILLS -> $target (was -> $cur_target)"
        fi ;;
      absent)
        rm -f "$AGENTS_SKILLS"
        echo "install-codex: reverted — removed symlink $AGENTS_SKILLS (path was absent before install)" ;;
      realdir)
        echo "install-codex: ERROR original was a real directory but $AGENTS_SKILLS is now a symlink — cannot restore the directory." >&2
        echo "install-codex: leaving the symlink in place; inspect manually, then rm -f '$STATE' '$LINKS'." >&2
        exit 1 ;;
    esac
  else # current=absent
    case "$kind" in
      symlink)
        ln -s "$target" "$AGENTS_SKILLS"
        echo "install-codex: reverted — restored $AGENTS_SKILLS -> $target (path had gone missing)" ;;
      absent)
        echo "install-codex: reverted — $AGENTS_SKILLS already absent (matches pre-install state)" ;;
      realdir)
        echo "install-codex: WARN original was a real directory but $AGENTS_SKILLS is gone — nothing to restore (revert touched no data)." ;;
    esac
  fi

  rm -f "$STATE" "$LINKS"
  # If install created ~/.agents itself, remove it again when empty (best-effort).
  if [ "$dir_created" = "1" ]; then
    rmdir "$AGENTS_DIR" 2>/dev/null || true
  fi
  return 0
}

install() {
  if [ -z "${PLUGIN_ROOT:-}" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    echo "install-codex: ERROR plugin root '${PLUGIN_ROOT:-}' is not a directory." >&2
    exit 2
  fi
  # Resolve to an absolute path FIRST — a relative root passes the -d checks from the
  # caller's CWD but is stored verbatim in the symlinks, which then resolve relative to
  # ~/.agents/skills and ALL dangle.
  PLUGIN_ROOT="$(cd "$PLUGIN_ROOT" && pwd)" || {
    echo "install-codex: ERROR cannot resolve plugin root to an absolute path." >&2
    exit 2
  }
  if [ ! -d "$PLUGIN_ROOT/skills" ]; then
    echo "install-codex: ERROR plugin root '$PLUGIN_ROOT' has no skills/ directory." >&2
    exit 2
  fi

  # Link every plugin skill (Codex resolves skills by bare name; v2 ships one Codex
  # adapter over the shared runtime-neutral skills).
  ADAPTERS="$(cd "$PLUGIN_ROOT/skills" && ls -d */ 2>/dev/null | sed 's#/##')"
  if [ ! -d "$PLUGIN_ROOT/skills/$REQUIRED_ADAPTER" ]; then
    echo "install-codex: ERROR the Codex adapter '$REQUIRED_ADAPTER' is missing from the plugin." >&2
    exit 2
  fi

  # Classify before mutating: a plain file at the skills path is user data.
  if [ -e "$AGENTS_SKILLS" ] && [ ! -L "$AGENTS_SKILLS" ] && [ ! -d "$AGENTS_SKILLS" ]; then
    echo "install-codex: ERROR $AGENTS_SKILLS exists and is a plain file — refusing to touch it." >&2
    echo "install-codex: move it aside, then re-run." >&2
    exit 2
  fi

  record_state_once

  # Convert a symlink (or an absent path) into a real directory; refresh a real dir.
  if [ -L "$AGENTS_SKILLS" ]; then
    rm -f "$AGENTS_SKILLS"  # removes only the symlink itself, never its target
    mkdir -p "$AGENTS_SKILLS"
  elif [ ! -d "$AGENTS_SKILLS" ]; then
    mkdir -p "$AGENTS_SKILLS"
  fi

  # The link manifest is regenerated on every install run (idempotent re-install).
  : > "$LINKS"

  # (a) Re-link every personal skill from ~/.claude/skills (adapters handled in (b)).
  if [ -d "$CLAUDE_SKILLS" ]; then
    for d in "$CLAUDE_SKILLS"/*; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      is_adapter "$name" && continue
      link_one "$d" "$AGENTS_SKILLS/$name" || true
    done
  else
    echo "install-codex: WARN $CLAUDE_SKILLS not found — only adapter links will be created."
  fi

  # (b) Link the five Codex IDC adapters to the installed plugin copy.
  linked=0
  for name in $ADAPTERS; do
    target="$PLUGIN_ROOT/skills/$name"
    if [ ! -d "$target" ]; then
      echo "install-codex: WARN adapter missing in plugin: $target"
      continue
    fi
    if link_one "$target" "$AGENTS_SKILLS/$name"; then
      linked=$((linked + 1))
    fi
  done

  # (c) Prune STALE mirror links. The manifest ($LINKS) was just regenerated with exactly the
  # links this run created, so any SYMLINK in $AGENTS_SKILLS that is NOT in the manifest — or
  # that no longer resolves — is a leftover from an earlier install (e.g. a ~/.claude/skills
  # entry deleted since the last run) and is removed. Mirrors link_one's safety posture: only
  # ever delete symlinks, never a real file or directory we did not create.
  pruned=0
  for entry in "$AGENTS_SKILLS"/*; do
    [ -L "$entry" ] || continue                      # symlink-only — never touch a real file/dir
    if grep -qxF "$(basename "$entry")" "$LINKS" 2>/dev/null && [ -e "$entry" ]; then
      continue                                       # current link that still resolves — keep it
    fi
    rm -f "$entry"                                    # removes only the symlink, never its target
    pruned=$((pruned + 1))
  done
  [ "$pruned" -gt 0 ] && echo "install-codex: pruned $pruned stale mirror link(s)."

  # Verify each plugin-skill link resolves to a real SKILL.md (two-hop reachability).
  total=0; resolved=0
  for name in $ADAPTERS; do
    total=$((total + 1))
    if [ -f "$AGENTS_SKILLS/$name/SKILL.md" ]; then
      resolved=$((resolved + 1))
    else
      echo "install-codex: WARN skill link does not resolve: $AGENTS_SKILLS/$name"
    fi
  done

  echo "install-codex: linked $linked skill(s); $resolved/$total resolve to SKILL.md."
  if [ ! -f "$AGENTS_SKILLS/$REQUIRED_ADAPTER/SKILL.md" ]; then
    echo "install-codex: ERROR the Codex adapter '$REQUIRED_ADAPTER' link does not resolve — install FAILED." >&2
    exit 1
  fi
  if [ "$resolved" -ne "$total" ]; then
    echo "install-codex: ERROR only $resolved/$total skill links resolve — install FAILED." >&2
    echo "install-codex: fix the warnings above (path collisions), then re-run." >&2
    exit 1
  fi
  echo "install-codex: Codex skill view is now the real directory $AGENTS_SKILLS"
  echo "install-codex: run 'install-codex.sh --revert' to restore the original state."
}

case "${1:-}" in
  --revert)
    revert ;;
  "")
    echo "usage: install-codex.sh <plugin_root> | --revert" >&2
    exit 2 ;;
  *)
    PLUGIN_ROOT="$1"
    install ;;
esac
