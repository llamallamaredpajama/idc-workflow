#!/bin/bash
# lint-references.sh — reference-integrity linter for the idc plugin (v2).
#
# Enforces v2 reference hygiene over plugin content that ships to users
# (agents/ skills/ commands/ templates/):
#
#   A. Every namespaced reference `idc:<name>` resolves to a real component in this repo —
#      skills/<name>/, agents/<name>.md, or commands/<name>.md (no dangling refs). Writing
#      `idc:<name>` ASSERTS that <name> ships here, so Rule A ignores the lint-allow marker
#      by design — there is no sanctioned dangling namespaced ref.
#   B. Every ${CLAUDE_PLUGIN_ROOT}/<path> and ../<path> file token resolves to a real file.
#   C. No machine-local paths (~/.claude/{agents,skills,commands,plugins}/, /Users/<user>)
#      or personal-memory references. The vendored runtime/ tree (idc-pi launcher, role
#      prompts, extensions) ships to users too, so it gets a dedicated machine-local-path
#      scan below — markdown-surface globbing would otherwise miss its non-.md files.
#   D. No "Knowledge Engine" project naming outside the history allowlist.
#   E. Frontmatter `name:` is bare (the harness adds the idc: namespace) AND matches the
#      component's directory/file stem.
#   G. A bare `idc-<component>` mention that resolves to a real component must be namespaced
#      `idc:idc-<component>` (catches un-namespaced skill/agent references in body text).
#
# Exit 0 = clean. Exit 1 = findings printed as <file>:<line>: <rule> <excerpt>.
# Lines containing "lint-allow" are exempt for Rules B–G (use sparingly, with a reason);
# Rule A ignores the marker by design (see above).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

FAIL=0
report() { echo "$1"; FAIL=1; }

# Scanned surfaces: plugin content that ships to users. (No spaces in repo filenames;
# plain word-splitting is safe and bash-3.2 compatible.) A surface dir may be absent
# mid-rebuild — find tolerates that with 2>/dev/null.
MD_FILES=$(find agents skills commands templates -name '*.md' 2>/dev/null | sort)
[ -z "$MD_FILES" ] && { echo "no content files found — run from repo root"; exit 2; }
FILE_COUNT=$(echo "$MD_FILES" | wc -l | tr -d ' ')

# History allowlist: files allowed to mention migration history / the original project.
HISTORY_ALLOW='^(CHANGELOG\.md|docs/dev/)'

# Rule C personal/machine-local path sub-pattern, shared by the markdown per-file scan and the
# runtime/ scan so the two cannot drift. The per-file scan layers personal-memory alternatives
# on top of this; the runtime/ scan uses it alone (those memory tokens would false-match code).
PERSONAL_PATH_RE='~/\.claude/(agents|skills|commands|plugins)/|/Users/[a-z]+'

filtered_grep() { # pattern, file — grep -n minus lint-allow lines
  grep -nE -- "$1" "$2" 2>/dev/null | grep -v 'lint-allow' || true
}

# Real component names, for Rule G bare-ref detection.
COMPONENTS=$( { ls -d skills/*/ 2>/dev/null | sed 's|skills/||; s|/$||'; \
                ls agents/*.md 2>/dev/null | sed 's|agents/||; s|\.md$||'; \
                ls commands/*.md 2>/dev/null | sed 's|commands/||; s|\.md$||'; } | sort -u)
is_component() { printf '%s\n' "$COMPONENTS" | grep -qxF "$1"; }

for f in $MD_FILES; do
  # Rule C — personal / machine-local references.
  # ~/.claude/teams/ and ~/.claude/tasks/ are harness runtime paths (identical for every
  # user) and allowed; plugin-content paths under ~/.claude must be rewritten.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$f:${hit%%:*}: [personal-path-or-memory] ${hit#*:}"
  done < <(filtered_grep "($PERSONAL_PATH_RE|see memory|memory feedback_|(^|[^a-zA-Z0-9_])feedback_[a-z0-9_]+)" "$f")

  # Rule D — original project naming (outside history allowlist).
  if ! echo "$f" | grep -qE "$HISTORY_ALLOW"; then
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      report "$f:${hit%%:*}: [project-naming] ${hit#*:}"
    done < <(filtered_grep '[Kk]nowledge[ -][Ee]ngine' "$f")
  fi

  # Rule B — shipped-path integrity: every ${CLAUDE_PLUGIN_ROOT}/<path> and ../<path>
  # file token must resolve. Placeholdered paths (<name>, …) never match and are skipped.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    for tok in $(echo "$line_txt" | grep -oE '(\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+\.(md|sh|ya?ml|json|py)|\.\./[A-Za-z0-9._/-]+\.(md|sh|ya?ml|json|py))'); do
      case "$tok" in
        ..*) rel="$(dirname "$f")/$tok" ;;
        *)   rel=$(printf '%s\n' "$tok" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||') ;;
      esac
      [ -f "$rel" ] || report "$f:$lineno: [dangling-path] $tok does not resolve to a file in this repo"
    done
  done < <(filtered_grep '(\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+\.(md|sh|ya?ml|json|py)|\.\./[A-Za-z0-9._/-]+\.(md|sh|ya?ml|json|py))' "$f")

  # Rule E — frontmatter name must be bare and match the component stem.
  fm_name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit} c>=2{exit}' "$f")
  if [ -n "$fm_name" ]; then
    case "$fm_name" in
      "name: idc:"*|"name: \"idc:"*|"name: 'idc:"*)
        report "$f: [namespaced-frontmatter-name] $fm_name (must be bare; harness adds idc:)" ;;
    esac
    nm=$(printf '%s\n' "$fm_name" | sed -E "s/^name:[[:space:]]*//; s/^[\"']//; s/[\"']$//")
    case "$f" in
      skills/*/SKILL.md) stem=$(printf '%s\n' "$f" | sed -E 's|skills/([^/]+)/SKILL.md|\1|') ;;
      agents/*.md)       stem=$(printf '%s\n' "$f" | sed -E 's|agents/(.+)\.md|\1|') ;;
      *) stem="" ;;
    esac
    if [ -n "$stem" ] && [ "$nm" != "$stem" ]; then
      report "$f: [frontmatter-name-mismatch] name: '$nm' != component stem '$stem'"
    fi
  fi

  # Rule G — a bare idc-<component> mention must be namespaced idc:idc-<component>.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    printf '%s\n' "$line_txt" | grep -qE '^name:' && continue            # frontmatter name
    printf '%s\n' "$line_txt" | grep -qE '^#{1,4} idc-[a-z0-9-]+' && continue  # H1–H4 self-title
    # strip namespaced refs and path tokens; a surviving bare component token is a finding
    residue=$(printf '%s\n' "$line_txt" | sed -E 's/idc:idc-[a-z0-9-]+//g; s#(skills/|agents/)idc-[a-z0-9-]+##g; s#\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+##g')
    for tok in $(printf '%s\n' "$residue" | grep -oE 'idc-[a-z0-9-]+' | sort -u); do
      if is_component "$tok"; then
        report "$f:$lineno: [bare-component-ref] $tok should be written idc:$tok"
      fi
    done
  done < <(filtered_grep 'idc-[a-z0-9-]+' "$f")
done

# Rule C (runtime/) — the vendored runtime tree ships to users but is not markdown and sits
# outside the surfaces globbed above. Scan every regular file under runtime/ for machine-local
# paths so a personal-path leak (e.g. /Users/<user> in the launcher) cannot hide there.
if [ -d runtime ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    rfile="${hit%%:*}"; rest="${hit#*:}"; rline="${rest%%:*}"; rtext="${rest#*:}"
    report "$rfile:$rline: [personal-path] $rtext"
  done < <(grep -rnE -- "($PERSONAL_PATH_RE)" runtime 2>/dev/null | grep -v 'lint-allow' || true)
fi

# Rule A — dangling namespaced references (ignores lint-allow by design).
ALL_REFS=$(grep -hoE 'idc:[a-z0-9][a-z0-9-]*' $MD_FILES 2>/dev/null | sort -u)
for ref in $ALL_REFS; do
  target="${ref#idc:}"
  if [ -d "skills/$target" ] || [ -f "agents/$target.md" ] || [ -f "commands/$target.md" ]; then
    continue
  fi
  report "(repo): [dangling-ref] $ref resolves to neither skills/$target, agents/$target.md, nor commands/$target.md"
done

# Rule H — release discipline (version lockstep + bump-on-ship). JSON/CHANGELOG parsing is
# delegated to a small dependency-free helper so it stays robust; any finding fails the lint.
if [ -f scripts/idc_release_check.py ]; then
  if ! rel_out=$(python3 scripts/idc_release_check.py 2>&1); then
    printf '%s\n' "$rel_out"
    FAIL=1
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "lint-references: CLEAN ($FILE_COUNT files scanned)"
else
  echo "lint-references: FAILURES FOUND (see lines above)"
fi
exit $FAIL
