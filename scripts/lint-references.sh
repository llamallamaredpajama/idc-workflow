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
#   C. No machine-local paths (~/.claude/{agents,skills,commands,plugins}<content>, /Users/<User>)
#      or personal-memory references. The content separator is any path char (a no-slash leak is
#      caught too); a bare standalone dir name stays exempt as a universal-harness mention. The
#      username class is case-insensitive. The vendored runtime/ tree (idc-pi launcher, role
#      prompts, extensions) ships to users too, so it gets a dedicated machine-local-path
#      scan below — markdown-surface globbing would otherwise miss its non-.md files.
#   D. No "Knowledge Engine" project naming outside the history allowlist.
#   E. Frontmatter `name:` is bare (the harness adds the idc: namespace) AND matches the
#      component's directory/file stem.
#   G. A bare `idc-<component>` mention that resolves to a real component must be namespaced
#      `idc:idc-<component>` (catches un-namespaced skill/agent references in body text).
#   I. No doubled namespace prefix `idc:idc:<x>` (the correct form is `idc:idc-<name>`).
#   J. Every `/idc:<token>` slash command names one of the real commands, derived from
#      commands/*.md so the count can't go stale as commands are added (typos and a slash pointed
#      at a skill/agent — which Rule A's resolution check passes — are caught here).
#   K. No `idc-` reference broken across a line break (Rule G is line-based and misses it).
#   M. No closing keyword (Closes/Fixes/Resolves #N) wrapped in backticks — GitHub's auto-close
#      parser only recognizes plain, unbackticked text, so a backtick-fenced keyword never
#      populates `closingIssuesReferences` and merging the PR never closes the issue.
#   N. No raw board-mutation DIRECTIVE in shipped orchestrator prose — the transition engine
#      (idc_transition.py) is the single write door (v4 Phase 2), so a shipped agent/command that
#      tells the reader to run `gh project item-edit|item-add|item-delete` or a GraphQL board write
#      (updateProjectV2ItemFieldValue / addProjectV2ItemById / deleteProjectV2Item) routes AROUND
#      the door (the improvisation class Stage 3's PreToolUse interlock catches at runtime). The
#      backend adapter skill idc-tracker-github IS the sanctioned low-level implementation the engine
#      wraps, so it is exempt; a PROHIBITION ("no raw …", "never …") naming the snippet to forbid it
#      is exempt (negation cue on the line); an explicit `lint-allow` marker is exempt.
#   R. No shipped surface may DIRECT a caller at a Path Gate minting door — neither the deleted
#      `idc_path_gate.py authorize` verb (V-DOOR) nor the scenario mint fixture
#      `tests/smoke/lib/path_gate_authorize.py`, which ships inside the plugin package. Minting is
#      admission-side. Negation cue / lint-allow exempt, exactly as Rule N.
#   S. Every BARE repo-relative shipped-path token (`scripts/x.py`, `templates/x.yaml`) resolves to a
#      real file. Rule B covers only the `${CLAUDE_PLUGIN_ROOT}/…` and `../…` spellings, but the
#      DOMINANT way shipped prose names a helper is the bare form — so a helper renamed out from
#      under its prose stayed lint-CLEAN (#211). Only PLUGIN-OWNED top dirs are checked: a
#      `docs/workflow/…` token names the GOVERNED repo's file, never one of ours. Negation
#      cue / lint-allow exempt, exactly as Rule N (prose that names a path to say it is NOT the one).
#   T. No shipped surface names a helper by ALIAS alone. IDC calls the read-only next-action helper
#      "the oracle"; its shipped file is `scripts/idc_next_action.py`. A playbook that says "call the
#      oracle" without naming that file ANYWHERE in the document leaves the reader to guess it — and
#      a real e2e driver guessed `scripts/idc_oracle.py`, which has never shipped (#211). Rule S
#      cannot catch that class: there is no stale token to dangle, only an unbound alias. Each alias
#      in ALIAS_BINDINGS must therefore be bound to its real helper at least once per file.
#
# Exit 0 = clean. Exit 1 = findings printed as <file>:<line>: <rule> <excerpt>.
# Lines containing "lint-allow" are exempt for Rules B–K (use sparingly, with a reason);
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
# The separator after a plugin dir is now any path char, not only `/` — so a no-slash CONTENT leak
# (`~/.claude/skills.bak`, `~/.claude/agents-mirror`) is caught, not just `~/.claude/skills/foo`. A
# BARE standalone dir name (`~/.claude/skills` followed by whitespace/backtick/EOL) stays exempt:
# it is a universal-harness mention, the same class as the allowed ~/.claude/teams ~/.claude/tasks
# (doctor.md's Codex-mirror check legitimately describes ~/.claude/skills this way). The username
# class is case-insensitive so a Capitalized `/Users/Jeremy` is caught too.
PERSONAL_PATH_RE='~/\.claude/(agents|skills|commands|plugins)[A-Za-z0-9._/-]|/Users/[A-Za-z]+'

# Rule S — the BARE repo-relative shipped-path token. One definition, used by both the detector and
# the per-line extractor so the two can never drift (a token the extractor cannot re-find would make
# a detected line silently report nothing). The leading class deliberately excludes `/` `$` `{` `-`
# and the path chars, so `${CLAUDE_PLUGIN_ROOT}/scripts/x.py`, `../scripts/x.py` and
# `docs/workflow/scripts/x.py` are NOT matched — the first two are Rule B's, the third is a governed
# repo's file. `-` is last inside the bracket expression (literal), per POSIX.
BARE_PATH_RE='(^|[^A-Za-z0-9._/${-])(scripts|hooks|templates|agents|skills|commands|tests)/[A-Za-z0-9._/-]+\.(py|sh|ya?ml|json|md|ts)'

# Rule T — alias→helper bindings, `<alias-regex>|<helper-file>`. Add a row when shipped prose starts
# calling a helper by a spoken name; the row is what forces that name to stay attached to a real
# shipping file. Kept as data so the rule never needs editing to cover a new alias.
ALIAS_BINDINGS='oracle|idc_next_action.py'

filtered_grep() { # pattern, file — grep -n minus lint-allow lines
  grep -nE -- "$1" "$2" 2>/dev/null | grep -v 'lint-allow' || true
}

filtered_grep_i() { # pattern, file — CASE-INSENSITIVE grep -n minus lint-allow lines
  grep -inE -- "$1" "$2" 2>/dev/null | grep -v 'lint-allow' || true
}

# Real component names, for Rule G bare-ref detection.
COMPONENTS=$( { ls -d skills/*/ 2>/dev/null | sed 's|skills/||; s|/$||'; \
                ls agents/*.md 2>/dev/null | sed 's|agents/||; s|\.md$||'; \
                ls commands/*.md 2>/dev/null | sed 's|commands/||; s|\.md$||'; } | sort -u)
is_component() { printf '%s\n' "$COMPONENTS" | grep -qxF "$1"; }

# Real slash-command stems, derived from commands/*.md, for Rule J. A /idc:<token> SLASH command
# must name one of these — a skill/agent is referenced WITHOUT a slash, so a slash pointed at a
# non-command (or a typo'd command) is a bug Rule A's component-resolution check cannot see.
COMMANDS=$(ls commands/*.md 2>/dev/null | sed 's|commands/||; s|\.md$||' | sort -u)
is_command() { printf '%s\n' "$COMMANDS" | grep -qxF "$1"; }

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

  # Rule I — a doubled namespace prefix (idc:idc:<x>). The correct namespaced-component form is
  # idc:idc-<name> (a hyphen, not a second colon), so a literal idc:idc: is always a mistake.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$f:${hit%%:*}: [doubled-namespace] ${hit#*:}"
  done < <(filtered_grep 'idc:idc:' "$f")

  # Rule J — a /idc:<token> slash command must name one of the real commands. `is_command()` checks
  # against $COMMANDS, derived from `ls commands/*.md` above — never a hardcoded count, so this
  # can't go stale as commands are added. The [a-z]-anchored token deliberately skips placeholders
  # (/idc:* , /idc:<cmd>); a surviving token that is not a command is a typo or a slash mistakenly
  # pointed at a skill/agent.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    for tok in $(printf '%s\n' "$line_txt" | grep -oE '/idc:[a-z][a-z-]*' | sed 's|/idc:||' | sort -u); do
      is_command "$tok" || report "$f:$lineno: [unknown-slash-command] /idc:$tok is not one of the IDC commands"
    done
  done < <(filtered_grep '/idc:[a-z][a-z-]*' "$f")

  # Rule K — an idc- reference broken across a line break (whitespace-tolerant). Rule G is
  # line-based, so a token soft-wrapped at its hyphen (a line ending in `idc-`, the rest resuming
  # the next line) slips past it. Flag the line that ends in `idc-` when the next line resumes with
  # a token char; lint-allow on the `idc-` line exempts it.
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    report "$f:$ln: [split-component-ref] an 'idc-' reference is broken across this line break"
  done < <(awk '
    NR>1 && prev ~ /idc-[ \t]*$/ && prev !~ /lint-allow/ && $0 ~ /^[ \t]*[a-z0-9]/ { print prevno }
    { prev=$0; prevno=NR }' "$f")

  # Rule M — a backtick-wrapped closing keyword (Closes/Fixes/Resolves #N, any tense GitHub
  # recognizes) defeats GitHub's auto-close parser: closingIssuesReferences never populates, so
  # merging the PR never closes the issue (the audit found this on every checked PR). Only the
  # backtick-fenced form is a violation — plain unbackticked text is the correct, working form.
  # GitHub's own keyword match is fully case-INsensitive (CLOSES / cLoSeS #5 both auto-close), so
  # this uses filtered_grep_i rather than hand-bracketing every letter's case.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$f:${hit%%:*}: [backticked-closing-keyword] ${hit#*:}"
  done < <(filtered_grep_i '`(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+`' "$f")

  # Rule N — no raw board-mutation DIRECTIVE in shipped orchestrator prose (route through the single
  # write door idc_transition.py). The adapter skill idc-tracker-github is THE sanctioned home for the
  # raw primitive the engine wraps → exempt the whole file. A prohibition ("no raw …", "never …")
  # naming the snippet to forbid it carries a negation cue on the line → exempt. `lint-allow` (via
  # filtered_grep) exempts an explicit future exception. A bare directive with none of these fails.
  case "$f" in
    skills/idc-tracker-github/SKILL.md) : ;;   # sanctioned board-mutation implementation
    *)
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        lineno="${hit%%:*}"; line_txt="${hit#*:}"
        printf '%s\n' "$line_txt" | grep -qiE '\b(no|never|not|without|dont|don.t|instead|rather)\b' && continue
        report "$f:$lineno: [raw-board-mutation-prose] route board writes through idc_transition.py (the single write door), not a raw gh project/GraphQL call: ${line_txt}"
      done < <(filtered_grep 'gh project item-(edit|add|delete)|updateProjectV2ItemFieldValue|addProjectV2ItemById|deleteProjectV2Item' "$f")
      ;;
  esac

  # Rule R — no shipped surface may direct a caller at a Path Gate MINTING door. Minting an
  # authorization is an admission-side privilege: production mints happen inside
  # `idc_command_entry_gate._ensure_path_gate_auth` and `idc_command_contract._mint_or_rollback`, and
  # `scripts/idc_path_gate.py` deliberately exposes NO `authorize` verb (V-DOOR) because the one it
  # used to expose honored caller-chosen --command/--allow-action/--allow-path. Two doors could
  # reappear in prose alone, with nothing to catch them:
  #   * `idc_path_gate.py authorize …` — a playbook re-adding the deleted verb. The verb's ABSENCE is
  #     asserted structurally by `governance/path-gate-boundaries.sh` D2 §3b; this catches the shipped
  #     INSTRUCTION, which is what would motivate someone to re-add it.
  #   * `tests/smoke/lib/path_gate_authorize.py` — the scenario mint fixture. `tests/` IS inside the
  #     published package (marketplace source is "./"), so that path exists on every governed machine;
  #     it now refuses outside a signalled scratch tree, but a shipped playbook must never point at it.
  # A prohibition naming the door in order to forbid it carries a negation cue → exempt. `lint-allow`
  # (via filtered_grep) exempts an explicit, reasoned exception. A bare directive fails.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    printf '%s\n' "$line_txt" | grep -qiE '\b(no|never|not|without|dont|don.t|deleted|removed|refuses)\b' && continue
    report "$f:$lineno: [path-gate-mint-directive] shipped prose points a caller at a Path Gate minting door; minting is admission-side (idc_command_entry_gate / idc_command_contract), idc_path_gate.py has no authorize verb, and the scenario fixture is not an authorization door: ${line_txt}"
  done < <(filtered_grep "idc_path_gate\.py['\"\`]?[[:space:]]+authorize([[:space:]]|['\"\`]|$)|path_gate_authorize\.py" "$f")

  # Rule S — BARE shipped-path integrity (the other half of Rule B). Rule B resolves only the
  # `${CLAUDE_PLUGIN_ROOT}/…` and `../…` spellings; the bare repo-relative form is how most shipped
  # prose actually names a helper (`scripts/idc_next_action.py`, `templates/workflow-machine.yaml`),
  # and it was unchecked — so a helper renamed out from under its prose left a stale name shipping
  # CLEAN (#211). Scope is deliberately the PLUGIN-OWNED top dirs only: `docs/workflow/…` and
  # `.claude/…` tokens name files in the GOVERNED repo, which does not exist at lint time.
  # The leading-char class excludes `/` and `$`, so a ${CLAUDE_PLUGIN_ROOT}- or ../-prefixed token is
  # left to Rule B and never double-reported here. A negation cue on the line is exempt — the Rule N/R
  # idiom for prose that names a path precisely to say it is NOT the one (commands/update.md's
  # "**not** templates/docs-tree/workflow-machine.yaml" is the live example).
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"; line_txt="${hit#*:}"
    printf '%s\n' "$line_txt" | grep -qiE '\b(no|never|not|without|dont|don.t|instead|rather|unrelated)\b' && continue
    for tok in $(printf '%s\n' "$line_txt" \
        | grep -oE "$BARE_PATH_RE" \
        | sed -E 's|^[^A-Za-z]+||' | sort -u); do
      [ -f "$tok" ] || report "$f:$lineno: [dangling-shipped-path] $tok does not resolve to a file in this repo"
    done
  done < <(filtered_grep "$BARE_PATH_RE" "$f")

  # Rule T — an alias must be BOUND to the helper it names. See the header note: the failure this
  # closes is a reader guessing a filename the alias never gave them. One entry per line,
  # `<alias-regex>|<helper-file>`; a file that uses the alias must name the helper somewhere in it.
  while IFS='|' read -r alias helper; do
    [ -z "$alias" ] && continue
    grep -qiE -- "$alias" "$f" 2>/dev/null || continue
    grep -qF -- "$helper" "$f" 2>/dev/null && continue
    report "$f: [unbound-helper-alias] this file calls it the \"${alias}\" but never names \`$helper\` — bind the alias to its real shipped helper at least once, or a reader must guess the filename"
  done <<EOF
$ALIAS_BINDINGS
EOF
done

# Rule O — workflow-machine.yaml cross-check.
# Every workflow state/transition NAME referenced in shipped prose must exist in
# templates/workflow-machine.yaml. This enforces:
#   - `Stage: <Name>` and `Status: <Name>` values match the `stages:`/`statuses:` lists.
#   - `eng <op-name>` invocations match the `ops:` list.
if [ -f scripts/idc_lint_machine_yaml_refs.py ]; then
  # The python script prints its own file:line: error reports, so here we just need to
  # capture the failure and set the global FAIL flag so the linter exits non-zero.
  if ! python3 scripts/idc_lint_machine_yaml_refs.py --machine-yaml templates/workflow-machine.yaml $MD_FILES; then
    FAIL=1
  fi
fi

# Rule O (=-forms, #157) — the python cross-check above matches only the `Stage: X` prose form,
# but the DOMINANT shipped forms are `Stage = Buildable` / `Stage=Recirculation` / `Status=Todo`
# (commands/autorun.md, agents/idc-autorun.md, agents/idc-recirculator.md, templates/WORKFLOW.md, …),
# so a stale or misspelled state name in those forms passed the cross-check. Validate them here
# against the same machine table. One awk pass (POSIX-only — runs identically on /usr/bin/awk,
# mawk, gawk; the interactive shell's grep is ugrep, so nothing here may lean on GNU extensions):
# the first file loads the `stages:`/`statuses:` inline flow lists, every later file is scanned.
# The value grammar mirrors the python's `:`-form ([A-Z]-anchored words), with the #157
# false-positive traps handled explicitly:
#   * multiword values: `Status = In Progress` validates as one name;
#   * prose continuation: `Status = Todo Because …` validates by its FIRST word when the full
#     capture is not a name (the value is Todo; the prose is commentary);
#   * compound/slash forms: `Stage = Recirculation ∧ Todo`, `Stage = Consideration/Planning` —
#     the capture stops at the non-name char and the leading name validates (same as the `:` form);
#   * `lint-allow` lines are exempt, like every other shell rule here.
if [ -f templates/workflow-machine.yaml ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report "$hit"
  done < <(awk '
    function loadset(line, set,    n, parts, i, v) {
      sub(/^[^[]*\[/, "", line); sub(/\].*$/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        v = parts[i]; gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
        if (v != "") set[v] = 1
      }
    }
    NR == FNR {
      if ($0 ~ /^stages:[ \t]*\[/) loadset($0, vstage)
      else if ($0 ~ /^statuses:[ \t]*\[/) loadset($0, vstatus)
      next
    }
    index($0, "lint-allow") { next }
    {
      s = $0
      while (match(s, /(^|[^A-Za-z_])(Stage|Status)[ \t]*=[ \t]*[A-Z][A-Za-z]*([ \t][A-Z][A-Za-z]*)*/)) {
        m = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        sub(/^[^A-Za-z_]/, "", m)
        key = (substr(m, 1, 6) == "Status") ? "Status" : "Stage"
        val = m; sub(/^(Stage|Status)[ \t]*=[ \t]*/, "", val)
        first = val; sub(/[ \t].*$/, "", first)
        if (key == "Stage") ok = (val in vstage) || (first in vstage)
        else ok = (val in vstatus) || (first in vstatus)
        if (!ok) printf "%s:%d: [machine-yaml-eq-ref] Invalid %s reference: \047%s\047 (= form; must name a templates/workflow-machine.yaml state)\n", FILENAME, FNR, key, val
      }
    }' templates/workflow-machine.yaml $MD_FILES)
fi

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

# Rule L — plugin manifest must not re-declare the auto-discovered standard hooks file. Claude Code
# auto-loads a plugin's standard-path hooks/hooks.json; a manifest `hooks` value pointing at that
# same file makes the loader abort with "Duplicate hooks file detected … manifest.hooks should only
# reference additional hook files". manifest.hooks is ONLY for ADDITIONAL hook files at non-standard
# paths, so a reference to hooks/hooks.json (with or without a ./ or / prefix) is always the
# duplicate. (Regression guard for the 3.1.0 → 3.1.1 plugin-load fix.) An additional-file reference
# like ./hooks/extra.json is deliberately NOT matched and stays legal.
if [ -f .claude-plugin/plugin.json ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    report ".claude-plugin/plugin.json:${hit%%:*}: [duplicate-hooks-manifest] manifest hooks points at the auto-discovered hooks/hooks.json — remove the \"hooks\" key (manifest.hooks is only for additional non-standard hook files)"
  done < <(grep -nE '"hooks"[[:space:]]*:[[:space:]]*"\.?/?hooks/hooks\.json"' .claude-plugin/plugin.json 2>/dev/null || true)
fi

# Rule P — the hooks.json UserPromptExpansion matcher must name EXACTLY the real command set.
# The command entry gate only runs for names the matcher admits; a command added to commands/*.md
# but not to the matcher would ship with NO freshness gate, NO lifecycle record, and NO closeout
# enforcement — the whole command-integrity chain silently absent for that one command. Compare the
# matcher's alternation set against the commands/*.md stems ($COMMANDS above), both sorted.
if [ -f hooks/hooks.json ]; then
  MATCHER_CMDS=$(python3 - <<'PY'
import json, re, sys
try:
    with open("hooks/hooks.json", encoding="utf-8") as fh:
        doc = json.load(fh)
    matchers = [e.get("matcher", "") for e in doc.get("hooks", {}).get("UserPromptExpansion", [])]
except Exception as exc:  # noqa: BLE001 — report the parse failure as the finding
    print(f"PARSE-ERROR: {exc}")
    sys.exit(0)
names = set()
for pat in matchers:
    m = re.fullmatch(r"\^idc:\(([a-z|-]+)\)\$", pat or "")
    if m:
        names.update(m.group(1).split("|"))
if not names:
    print(f"PARSE-ERROR: no ^idc:(...)$ UserPromptExpansion matcher found in {matchers!r}")
    sys.exit(0)
print("\n".join(sorted(names)))
PY
)
  case "$MATCHER_CMDS" in
    PARSE-ERROR:*)
      report "hooks/hooks.json: [entry-gate-matcher] cannot extract the UserPromptExpansion matcher command set ($MATCHER_CMDS)"
      ;;
    *)
      if [ "$MATCHER_CMDS" != "$COMMANDS" ]; then
        report "hooks/hooks.json: [entry-gate-matcher] the UserPromptExpansion matcher set ($(printf '%s' "$MATCHER_CMDS" | tr '\n' ' ')) differs from commands/*.md ($(printf '%s' "$COMMANDS" | tr '\n' ' ')) — a command missing from the matcher ships with NO entry gate, lifecycle record, or closeout enforcement"
      fi
      ;;
  esac
fi

# Rule Q — every GitHub Actions `uses:` under .github/workflows/ must be pinned to a FULL 40-hex
# commit SHA. A tag or branch ref (`@v4`, `@main`) is MUTABLE: the action's owner — or anyone who
# compromises that account — can re-point it at arbitrary code, which then runs with this workflow's
# token and secrets. That matters more here than in an ordinary repo, because
# .github/workflows/idc-pathway-integrity.yml emits the REQUIRED `idc/pathway-integrity` check that
# gates every governed merge: a swapped action can fail the checkout (blocking all merges) or fake a
# pass. Verification of a pin value was previously live-CI-only; this rule makes it hermetic.
# A trailing `# <tag>` comment is the human-readable record of WHICH release the SHA is, and is not
# checked — the SHA is what runs. Local composite actions (`uses: ./…`) are exempt: they resolve to
# code inside this repo, already covered by CODEOWNERS and the pathway checker's protected surfaces.
# Anything else (including a `docker://` ref) must be a 40-hex SHA or it fails here by design.
# Deliberately NOT lint-allow-exemptible: a supply-chain pin with a per-line bypass is not a pin.
#
# The MATCHING is the security-relevant half of this rule: a `uses:` spelling the detector does not
# see is an unpinned action that lints CLEAN. Four spellings previously slipped through, all of them
# valid YAML that GitHub Actions executes exactly like the canonical form:
#   * `uses : actions/checkout@v4` — YAML permits whitespace before the `:`;
#   * `- {uses: actions/checkout@v4}` and `- {name: x, uses: y@v4}` — FLOW mappings, where `uses`
#     is not the first thing on the line;
#   * `uses: "actions/checkout@<40-hex>"` — a correctly pinned but QUOTED ref, whose trailing quote
#     broke the `@<sha>$` anchor and produced a FALSE POSITIVE on a good pin;
#   * `uses: ./../../elsewhere` — the local-action exemption matched any `./` prefix, so a `..`
#     traversal out of this repository's own action surface was silently exempted.
# So: the detector accepts whitespace before the colon and `uses` after a `{` or `,`; the extractor
# strips flow-mapping punctuation and surrounding quotes before the anchor test; and the local
# exemption requires a `./` path with NO `..` component.
if [ -d .github/workflows ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    qfile="${hit%%:*}"; qrest="${hit#*:}"; qline="${qrest%%:*}"; qtext="${qrest#*:}"
    # Take everything after the LAST `uses` key on the line (so `{name: a, uses: b}` yields `b`),
    # then the first whitespace-separated field (a trailing `# v4` comment falls away), then peel
    # flow-mapping punctuation and surrounding quotes off the ref itself.
    qref=$(printf '%s\n' "$qtext" \
      | sed -E 's/^.*uses[[:space:]]*:[[:space:]]*//' \
      | awk '{print $1}' \
      | sed -E 's/[},]+$//' \
      | sed -E "s/^['\"]//; s/['\"]\$//")
    [ -z "$qref" ] && continue
    case "$qref" in
      *..*)
        # A `..` component leaves this repository's action surface, so the in-repo rationale for the
        # local exemption does not hold; it is neither exempt nor pinnable as written.
        report "$qfile:$qline: [unpinned-action] \`uses: $qref\` is a LOCAL action reference containing a \`..\` component, which points outside this repository's own action surface — the local-action exemption covers only in-repo \`./\` paths (already governed by CODEOWNERS and the pathway checker). Use a path with no \`..\`, or reference the upstream action pinned to a full 40-hex commit SHA"
        continue ;;
      ./*) continue ;;   # local composite action — in-repo code, no upstream SHA to pin
    esac
    if ! printf '%s\n' "$qref" | grep -qE '@[0-9a-f]{40}$'; then
      report "$qfile:$qline: [unpinned-action] \`uses: $qref\` is not pinned to a full 40-hex commit SHA — a moving tag/branch ref lets the action owner (or a compromised account) change what runs in this workflow. Resolve it with \`gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha\` and keep a trailing \`# <tag>\` comment for readability"
    fi
  done < <(grep -rnE '(^[[:space:]]*(-[[:space:]]*)?\{?|[{,])[[:space:]]*uses[[:space:]]*:[[:space:]]*[^[:space:]]' .github/workflows 2>/dev/null || true)
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
