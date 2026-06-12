#!/bin/bash
# lint-references.sh — reference-integrity linter for the idc plugin repo.
#
# Enforces the Phase B rewrite rules (see docs/dev/phase-0-spike-findings.md):
#   1. No bare skill/agent references in body text — must be plugin-namespaced (idc:...).
#      Rules 1a/1b SKIP skills/codex-idc-*/SKILL.md: those are Codex-native bodies and
#      reference bare names BY DESIGN — the Codex runtime resolves skills by bare
#      directory name through the ~/.agents/skills chain; the idc: namespace exists
#      only in the Claude harness. Rules 2/3/4/6/7 still apply to them.
#   2. No ~/.claude/ paths, no /Users/<user> paths, no personal-memory references.
#   3. No legacy /agent-* command forms.
#   4. No "Knowledge Engine" project naming outside the history allowlist.
#   5. Every namespaced reference resolves to a real file in this repo (no dangling refs).
#      Rule 5 deliberately BYPASSES lint-allow: writing idc:X asserts that X ships in
#      this plugin, so there is no sanctioned way to keep a dangling namespaced ref.
#      For historical / never-authored names, write the BARE name + lint-allow instead
#      (see docs/dev/known-debts.md §Handling policy).
#   6. Every ${CLAUDE_PLUGIN_ROOT}/<path>.md and ../<path>.md token resolves to a real
#      file in this repo (no dangling shipped-path claims).
#   7. Frontmatter name: fields must be bare (never idc:-prefixed) — the harness adds
#      the plugin namespace itself at load time.
#
# Exit 0 = clean. Exit 1 = findings printed as <file>:<line>: <rule> <excerpt>.
# Lines containing "lint-allow" are exempt (use sparingly, with a reason) — except
# under Rule 5, which ignores the marker by design (see above).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

FAIL=0
report() { echo "$1"; FAIL=1; }

# Scanned surfaces: plugin content that ships to users.
# (no spaces in repo filenames; plain word-splitting is safe and bash-3.2 compatible)
MD_FILES=$(find agents skills commands templates -name '*.md' 2>/dev/null | sort)
[ -z "$MD_FILES" ] && { echo "no content files found — run from repo root"; exit 2; }
FILE_COUNT=$(echo "$MD_FILES" | wc -l | tr -d ' ')

# History allowlist: files allowed to mention migration history / original project.
HISTORY_ALLOW='^(CHANGELOG\.md|docs/dev/)'

filtered_grep() { # pattern, file — grep -n minus lint-allow lines
  grep -nE -- "$1" "$2" 2>/dev/null | grep -v 'lint-allow' || true
}

for f in $MD_FILES; do
  # Codex-native adapter bodies reference bare names by design (Codex resolves skills
  # by bare directory name via ~/.agents/skills; idc: namespacing is Claude-only), so
  # Rules 1a/1b skip them. Every other rule still applies.
  case "$f" in
    skills/codex-idc-*/SKILL.md) codex_native=1 ;;
    *) codex_native=0 ;;
  esac

  if [ "$codex_native" -eq 0 ]; then
  # Rule 1a: bare idc-skill- / codex-idc- references.
  # Exempt: namespaced (idc:idc-skill-...), frontmatter name: lines, path tokens
  # (skills/idc-skill-..., ${CLAUDE_PLUGIN_ROOT}/skills/...).
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # hit is "lineno:text" (grep -n on a single file) — strip the line number ONCE;
    # a second strip would eat up to the namespace colon in refs like `idc:idc-skill-X`.
    line_txt="${hit#*:}"
    echo "$line_txt" | grep -qE '^name: (idc-skill-|codex-idc-|idc-workflow)' && continue
    # strip namespaced refs, plugin/skill path tokens, and docs/ path tokens (audit dirs
    # etc. legitimately contain idc-* substrings), then see if a bare ref remains
    residue=$(echo "$line_txt" | sed -E 's/idc:(idc-skill|codex-idc)-<[a-zA-Z0-9_-]+>//g; s/idc:(idc-skill|codex-idc)-[a-z0-9-]+//g; s|skills/(idc-skill\|codex-idc)-[a-z0-9-]+||g; s|docs/[a-zA-Z0-9/_+.-]*||g')
    if echo "$residue" | grep -qE '(idc-skill-|codex-idc-)'; then
      report "$f:${hit%%:*}: [bare-skill-ref] $line_txt"
    fi
  done < <(filtered_grep '(idc-skill-|codex-idc-)' "$f")

  # Rule 1b: bare idc-role- / orchestrator-agent references.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    line_txt="${hit#*:}"
    echo "$line_txt" | grep -qE '^name: idc-' && continue
    # H1 self-titles are bare by convention (the file's own name, matching the bare
    # frontmatter name: and the orchestrators' bare H1s) — exempt the exact-title form.
    echo "$line_txt" | grep -qE '^# idc-role-[a-z0-9-]+$' && continue
    # strip, in order: namespaced refs (incl. <placeholder> forms), .md file-path tokens
    # (any prefix — agents/, ../, ${CLAUDE_PLUGIN_ROOT}/…; a filename is a doc ref, not a
    # spawn ref), and docs/ paths
    residue=$(echo "$line_txt" | sed -E 's/idc:idc-role-<[a-zA-Z0-9_-]+>//g; s/idc:idc-role-[a-z0-9-]+//g; s/idc-role-<[a-zA-Z0-9_-]+>\.md//g; s/idc-role-[a-z0-9-]+\.md//g; s|docs/[a-zA-Z0-9/_+.-]*||g')
    if echo "$residue" | grep -qE 'idc-role-'; then
      report "$f:${hit%%:*}: [bare-agent-ref] $line_txt"
    fi
  done < <(filtered_grep 'idc-role-' "$f")
  fi # codex_native rule-1 skip

  # Rule 2: personal / machine-local references.
  # ~/.claude/teams/ and ~/.claude/tasks/ are harness runtime paths (identical for
  # every user) and are allowed; plugin-content paths under ~/.claude must be rewritten.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$f:${hit%%:*}: [personal-path-or-memory] ${hit#*:}"
  done < <(filtered_grep '(~/\.claude/(agents|skills|commands|plugins)/|/Users/[a-z]+|see memory|memory feedback_|(^|[^a-zA-Z0-9_])feedback_[a-z0-9_]+)' "$f")

  # Rule 3: legacy /agent-* command forms.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$f:${hit%%:*}: [legacy-command-form] ${hit#*:}"
  done < <(filtered_grep '/agent-(think|plan|sequence|build|ripple|autorun)' "$f")

  # Rule 4: original project naming (outside history allowlist).
  if ! echo "$f" | grep -qE "$HISTORY_ALLOW"; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      report "$f:${hit%%:*}: [project-naming] ${hit#*:}"
    done < <(filtered_grep '[Kk]nowledge[ -][Ee]ngine' "$f")
  fi

  # Rule 6: shipped-path integrity — every ${CLAUDE_PLUGIN_ROOT}/<path>.md and
  # ../<path>.md token must resolve to a real file (this was the blind spot that let
  # dangling path conversions ship; lint-allow respected). Placeholdered paths
  # (<name>, <phase-tag>, …) never match the token pattern and are naturally skipped.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    for tok in $(echo "$line_txt" | grep -oE '(\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+\.md|\.\./[A-Za-z0-9._/-]+\.md)'); do
      case "$tok" in
        ..*) rel="$(dirname "$f")/$tok" ;;
        *)   rel=$(printf '%s\n' "$tok" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||') ;;
      esac
      if [ ! -f "$rel" ]; then
        report "$f:$lineno: [dangling-path] $tok does not resolve to a file in this repo"
      fi
    done
  done < <(filtered_grep '(\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+\.md|\.\./[A-Za-z0-9._/-]+\.md)' "$f")

  # Rule 7: frontmatter name must be bare — the harness prefixes the plugin namespace
  # itself; a namespaced name: would surface as idc:idc:<name> at load time.
  fm_name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit} c>=2{exit}' "$f")
  case "$fm_name" in
    "name: idc:"*|"name: \"idc:"*|"name: 'idc:"*)
      report "$f: [namespaced-frontmatter-name] $fm_name" ;;
  esac
done

# Rule 5: dangling namespaced references — every idc:X must resolve.
ALL_REFS=$(grep -hoE 'idc:(idc-skill-[a-z0-9-]+|codex-idc-[a-z0-9-]+|idc-role-[a-z0-9-]+|idc-workflow|idc-build-runbook|think|plan|sequence|build|ripple|autorun|init|doctor)' $MD_FILES 2>/dev/null | sort -u)
for ref in $ALL_REFS; do
  target="${ref#idc:}"
  if [ -d "skills/$target" ] || [ -f "agents/$target.md" ] || [ -f "commands/$target.md" ]; then
    continue
  fi
  report "(repo): [dangling-ref] $ref resolves to neither skills/$target, agents/$target.md, nor commands/$target.md"
done

if [ "$FAIL" -eq 0 ]; then
  echo "lint-references: CLEAN ($FILE_COUNT files scanned)"
else
  echo "lint-references: FAILURES FOUND (see lines above)"
fi
exit $FAIL
