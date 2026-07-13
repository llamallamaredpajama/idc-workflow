#!/usr/bin/env python3
"""idc_interlock_gate.py — the PreToolUse mutation interlock (v4 Phase 2 §3.2; Task 3 command integrity).

Fired on PreToolUse for the Bash tool. The transition engine (idc_transition.py), the finisher tail
(idc_git_finish.py), and the sanctioned PR finisher (idc_pr_finish.py) are the ONE door to terminal
workflow state — but an agent can still type a raw `gh issue create` / `gh pr merge` / `gh issue
close` / state-closing or dependency `gh api` / raw board mutation (`gh project
item-add|item-edit|item-delete`, GraphQL board writes) directly into the Bash tool, bypassing the
door. That is exactly the 394ec6fe "hand-rolled finish / loose improvisation" class (forensic drops
C + D). The session-b7a93ff6 incident showed the escape hatch: the raw mutation was hidden inside a
throwaway `fire_gate.sh` and run as `bash fire_gate.sh`, so a pure command-string match saw only
`bash fire_gate.sh` and waved it through. This gate now sees THROUGH that indirection.

POSTURE (Task 3): the interlock is a HARD DENY while the session owns an ACTIVE `/idc:*` command
(idc_ledger.active_commands, scoped to the payload's session) — the window where a raw mutation is
the improvisation the pipeline forbids. OUTSIDE an active command it is a WARN-INJECT (surface the
remediation, never block) so ordinary governed-repo work is never bricked. IDC_HOOKS_OBSERVE_ONLY=1
is the ONE debug escape hatch — it downgrades any deny back to a warning (honored inside
pre_tool_deny()). There is no second bypass variable; the old IDC_HOOKS_INTERLOCK_ENFORCE opt-in is
removed (the active-command deny is the shipped enforcement). COMMAND-KEYED exceptions — a command may
perform its OWN declared lifecycle/provisioning ops (the ones with no engine door): while the active
command is `/idc:uninstall`, its teardown ops (issue close, project/board delete, item delete) are
allowed; while it is `/idc:init`, its board-provisioning ops (project field-create, repo link, the
Status option-reconcile `updateProjectV2Field` mutation) are allowed. Each is scoped to THAT command,
requires EVERY protected segment to be one of the ops it owns, and every other op stays denied.

CLASSIFIER (round-5 Fix 1): defense-in-depth by PER-SEGMENT classification, NOT a complete shell
parser. The command is split into shell segments (`&&`/`||`/`;`/`|`/newline) and EACH is classified
on its own tokens, so a decoy method flag in another segment (`: -X GET && gh api … -X DELETE`) can
never mask a write, and gh global flags (incl. `--hostname`) before the subcommand are stripped. A
`gh api` on a protected path (issue state/create/close, `dependencies/blocked_by`, graphql) is
FAIL-CLOSED — allowed only when provably a pure read (a defaulted/explicit GET/HEAD with no body and
no `--input`); an opaque `--input FILE`/ambiguous method DENIES. `env -S "<string>"` (with trailing
args) and `bash|sh|zsh < FILE` redirected stdin are followed through like any other indirection.

INDIRECTION-AWARE (bounded interpreter inspection). Beyond the direct command-string classifier,
inspect_command resolves:
  * quoted `bash -c '…'` / `sh -c '…'` / `zsh -c '…'` payloads (recursively);
  * `bash|sh|zsh FILE`, `source FILE`, and `. FILE` script targets (resolved against cwd), scanning
    the file body for a protected operation.
It is BOUNDED and SAFE: at most MAX_SCRIPT_DEPTH levels of nesting, files up to MAX_SCRIPT_BYTES,
regular files only, cycle-guarded. Files under the plugin's own `scripts/` dir are sanctioned (not
scanned). Sensitive targets (`.env`, `.envrc`, `*.pem`, `id_rsa*`, or names containing `credential`/
`secret`) are REFUSED WITHOUT being opened; unreadable / non-regular / too-large / cyclic /
depth-exhausted targets are refused as `opaque-script-indirection`. A denial NEVER echoes script
contents — only the normalized display path and the matched operation.

FAIL-CLOSED ON DYNAMIC/OPAQUE (round-9 Fix A). A static classifier cannot analyze Turing-complete
shell, so the residual bypass class is "hide a protected mutation behind a construct the classifier
cannot resolve." We close that class BY CONSTRUCTION rather than chase each variant: during an active
command we DENY (subject `dynamic-opaque-indirection`) when the command carries a construct that could
execute a hidden command or redirect an API surface and cannot be statically confirmed safe — command
substitution `$(…)`/backticks, process substitution `<(…)`/`>(…)` (carve-outs only, since only there
does the outer op get allowed), a `gh api` with a shell-expansion ENDPOINT (deny with any write
indicator; deny outright under a carve-out), a `BASH_ENV`/`ENV`/`SHELLOPTS`/`*ENV`/`*RC` startup-file
prefix before an interpreter, and a dynamic interpreter/`-c`/`env -S` target. Under the init/uninstall
carve-outs the bar is absolute: ANY such construct denies, because the carve-out's whole safety
argument is "every segment is a statically-recognized safe op" — only fully STATIC recognized
provisioning/teardown ops are ever allowed. This is defense-in-depth, not a complete shell parser; a
bare `$VAR` parameter expansion (a value, not an executed command) is deliberately never flagged.

Why this NEVER fires on the sanctioned path: the engine + finishers run `gh` via python subprocess,
NOT via the Bash tool, so PreToolUse never sees them; and a `python3 …/idc_transition.py …` /
`python3 …/idc_pr_finish.py …` Bash call does not invoke an interpreter FILE form and matches no
classifier pattern. Only a RAW terminal command (or one hidden behind interpreter indirection)
matches.

Invocation: idc_interlock_gate.py <PLUGIN_ROOT>   (PreToolUse payload on stdin).
Self-gated: no-op (allow) outside a governed repo, for non-Bash tools, or on a non-matching command.
"""
import dataclasses
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402
import idc_ledger as L    # noqa: E402  (active_commands — the deny-vs-warn signal)

# ── bounded interpreter-inspection limits + data (Task 3) ─────────────────────────────────────────
MAX_SCRIPT_DEPTH = 3
MAX_SCRIPT_BYTES = 65536
INTERPRETERS = {"bash", "sh", "zsh"}
SENSITIVE_BASENAMES = {".env", ".envrc", "id_rsa", "id_dsa", "id_ed25519"}


@dataclasses.dataclass(frozen=True)
class Finding:
    subject: str
    remediation: str
    source: str
    kind: str = ""   # stable operation tag (issue-close / project-delete / …) for policy decisions
                     # (Fix 2: keying the /idc:uninstall teardown allowance on the op, not a fragile
                     # subject-string match). Empty = untagged (indirection wrappers inherit the inner).


def _mk(subject, remediation, kind):
    """A direct-classifier Finding carrying its op `kind` (source is always the direct classifier)."""
    return Finding(subject, remediation, "direct", kind)


# ── remediations (every message names the EXACT door command, per P3 self-healing) ────────────────
_FINISH = (
    "run the receipt-gated finisher tail instead: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py --pr <N> --issue <M> "
    "--worktree <path> --verdict <verdict.json>` — it validates the review receipt, merges, and "
    "closes the tracker item through the single write door. For a planning/recirculation PR with no "
    "issue to close, use the sanctioned finisher: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_pr_finish.py autonomous --repo <repo> --pr <N> "
    "--kind planning|recirculation|intake`."
)
_CLOSE = (
    "the finisher closes the tracker item as part of `idc_git_finish.py` (above), or use the "
    "transition engine's guarded close directly: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo <repo> close <issue> "
    "--pr <N> --verdict <verdict.json>`."
)
_ENGINE = (
    "route it through the single write door: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo <repo> <op> …` "
    "(create-ticket | create-pointer | claim | move | set-field | close | dispose | "
    "recirculate-intake | link | unblock) — never mutate the board with a raw "
    "`gh issue`/`gh project`/GraphQL call."
)
_DEP = (
    "route the dependency through the single write door: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo <repo> link --parent <blocker> "
    "--child <blocked> --kind blocks` to add a block, or `… unblock --num <blocked> --by <gate>` to "
    "clear one — never a raw `gh api …/dependencies/blocked_by` POST/DELETE."
)

# Classifier rules, checked in order. `_has(*seqs)` → the command contains a whitespace-flexible run
# of words for EVERY seq (so `gh   pr   merge` and `cd x && gh pr merge --squash` both match, while
# `gh pr view` / `gh project item-list` do not).
_WS = r"\s+"


def _has(command, *word_seqs):
    """True iff `command` contains a run of whitespace-separated words for EVERY seq in `word_seqs`."""
    for seq in word_seqs:
        pat = _WS.join(re.escape(w) for w in seq.split())
        if not re.search(r"(?<![\w-])" + pat + r"(?![\w-])", command):
            return False
    return True


def _api_has_body(command):
    """True iff a `gh api` carries a body flag (`-f`/`-F`/`--field`/`--raw-field`/`--input`), in the
    space-separated (`-f k=v`) or combined (`-fk=v`) form — any body promotes the default GET to a POST."""
    return bool(re.search(r"(?<![\w-])(?:-[fF](?![\w-])|-[fF][A-Za-z_]|--field\b|--raw-field\b|--input\b)",
                          command))


def _api_write_indicator(seg_str):
    """True iff a `gh api` SEGMENT shows ANY write indicator (round-6 Fix 1+2 — BLUNT + fail-closed):
    a `-X`/`--method` whose value is not GET — scan ALL occurrences, since real gh uses the LAST `-X`,
    so a leading `-X GET` decoy can never mask a trailing `-X DELETE`; ANYTHING but a literal GET
    (`HEAD`, a write verb, or a shell-expansion `"$M"`) counts as a write — OR any body flag
    (`-f`/`-F`/`--field`/`--raw-field`/`--input`). Only a segment with NO non-GET method anywhere AND
    NO body flag is a provable pure read. When in doubt, treat it as a write (real mutations go through
    the Python engine doors)."""
    for m in re.finditer(r"(?:--method[=\s]+|-X[=\s]*)(\S+)", seg_str, re.I):
        if m.group(1).strip("\"'").upper() != "GET":
            return True
    return _api_has_body(seg_str)


# ── gh subcommand normalization (Fix 1: token-based, flag-placement-robust) ───────────────────────
# gh flags that CONSUME a following value token (space-separated form). The `--opt=val` and combined
# `-Rval`/`-XDELETE`/`-X=DELETE` forms are self-contained single tokens (skipped as one). Used to strip
# options at ANY level so the POSITIONAL word sequence (`issue create`, `pr merge`) is what's matched —
# a flag anywhere (`gh issue -R o/r create`) can no longer split the subcommand path.
_GH_VALUE_OPTS = {"-R", "--repo", "-H", "--hostname", "--jq", "-F", "-f", "--field", "--raw-field",
                  "-X", "--method", "--header", "--input", "--template"}
# Protected gh subcommand combos as (noun, verb) — matched on the POSITIONAL sequence (options at any
# level stripped), INCLUDING the `issue new` = `issue create` alias. Reads (`issue view`, `pr view`,
# `project item-list`) are absent, so a governed read is never flagged.
_PROTECTED_COMBOS = (
    {("issue", v) for v in ("create", "new", "close", "delete", "edit", "reopen", "lock", "unlock",
                            "transfer", "pin", "unpin")}
    | {("pr", v) for v in ("merge", "close", "edit")}
    | {("project", v) for v in ("item-add", "item-edit", "item-delete", "item-archive", "field-create",
                                "edit", "delete", "copy", "link", "unlink")}
)
# The GraphQL WRITE-mutation family: a write verb glued to a protected object (createProjectV2,
# copyProjectV2, linkProjectV2ToRepository, updateIssue, reopenIssue, clearProjectV2ItemFieldValue,
# archiveProjectV2Item, …). Pattern-matched (verb+object), NOT a hand-kept name list, so a NEW mutation
# name in the same family is caught. Case-sensitive (camelCase) to avoid matching ordinary prose.
_GQL_WRITE = re.compile(
    r"(?:create|update|delete|add|remove|copy|move|archive|unarchive|clear|convert|close|reopen|"
    r"mark|link|unlink|merge)(?:ProjectV2|Issue|PullRequest|Item|Field)")


def _gh_positionals(seg):
    """The POSITIONAL word sequence of a `gh …` command SEGMENT — options at ANY level stripped (incl.
    their consumed values and the self-contained `--opt=val`/`-Rval`/`-XDELETE` forms) — or None if the
    segment is not a `gh` invocation. `gh issue -R o/r create` → ['issue', 'create']; the subcommand
    path can no longer be split by a flag placed between levels."""
    seg = _strip_prefixes(seg)
    if not seg or os.path.basename(seg[0]) != "gh":
        return None
    words = []
    i = 1
    while i < len(seg):
        tok = seg[i]
        if tok == "--":
            words.extend(seg[i + 1:])         # everything after `--` is positional
            break
        if tok.startswith("-"):
            if tok in _GH_VALUE_OPTS and i + 1 < len(seg):
                i += 2                         # `-R o/r` / `--method DELETE` — consume the value token
            else:
                i += 1                         # `--repo=o/r`, `-Rval`, `-XDELETE`, or a bare flag
            continue
        words.append(tok)
        i += 1
    return words


def _combo_subject(pos):
    """A Finding (with op `kind`) if the positional sequence's leading (noun, verb) is a protected
    combo, else None. `kind` distinguishes uninstall-teardown ops (issue-close / project-delete /
    project-item-delete) from everything else so the Fix-2 allowance can key on the OP, not a string."""
    if not pos or len(pos) < 2:
        return None
    noun, verb = pos[0], pos[1]
    if (noun, verb) not in _PROTECTED_COMBOS:
        return None
    if noun == "issue":
        if verb == "close":
            return _mk("a raw `gh issue close`", _CLOSE, "issue-close")
        if verb in ("delete", "reopen"):
            return _mk(f"a raw `gh issue {verb}`", _CLOSE, f"issue-{verb}")
        kind = "issue-create" if verb in ("create", "new") else f"issue-{verb}"
        return _mk(f"a raw `gh issue {verb}`", _ENGINE, kind)
    if noun == "pr":
        return _mk(f"a raw `gh pr {verb}`", _FINISH, "pr-merge" if verb == "merge" else f"pr-{verb}")
    # field-create + link get DISTINCT kinds so the /idc:init provisioning carve-out can allow init's
    # own field creation + repo link while item-add/item-edit/delete (also `gh project` mutations) stay
    # denied even under init.
    kind = {"delete": "project-delete", "item-delete": "project-item-delete",
            "field-create": "project-field-create", "link": "project-link"}.get(verb, "project-mutation")
    return _mk("a raw `gh project` board mutation", _ENGINE, kind)


def _api_protected_path_kind(seg_str):
    """Which PROTECTED `gh api` write surface (if any) the segment TEXT names — scanned bluntly across
    the whole segment string (round-6 Fix 1+2: no positional endpoint isolation, which a mis-parsed
    value-taking flag like `-p nebula` could defeat): 'graphql' | 'dep' | 'issues', else None. An
    arbitrary read path (`repos/O/R`, `rate_limit`, …) matches none, so an ordinary `gh api` read is
    never touched."""
    if re.search(r"(?<![\w-])graphql(?![\w-])", seg_str):
        return "graphql"
    if "dependencies/blocked_by" in seg_str:
        return "dep"
    if re.search(r"repos/[^/\s'\"]+/[^/\s'\"]+/issues(?:/|[\s'\"?]|$)", seg_str):
        return "issues"
    return None


# round-8 Fix 1: isolate the VALUE of the graphql `query` argument specifically, WITH its quote style —
# `-f query=<v>` / `--field query=<v>` / `-F query=<v>` / `--raw-field query=<v>`, in the spaced,
# `--field=query=` and combined `-fquery=` forms. Quote style is load-bearing: a SINGLE-quoted value
# cannot be shell-expanded, so GraphQL `$vars` inside it are literal; a DOUBLE-quoted value with a `$`
# or backtick IS a shell expansion. We parse the RAW segment (not shlex tokens) because shlex strips the
# quotes and erases exactly that single-vs-double distinction.
_GQL_QUERY_ARG_RE = re.compile(
    r"""(?<![\w-])
        (?:
            (?:-f|-F|--field|--raw-field)\s+query=   # spaced:  -f query= / --field query=
          | (?:--field|--raw-field)=query=           # attached long: --field=query=
          | (?:-f|-F)query=                           # attached short: -fquery=
        )
        (?:
            '(?P<sq>[^']*)'                           # single-quoted (no shell expansion possible)
          | "(?P<dq>[^"]*)"                           # double-quoted ($/backtick ⇒ expansion)
          | (?P<bare>\S*)                             # bare / unquoted
        )
    """, re.VERBOSE)
# Project-FIELD provisioning mutations that /idc:init runs raw (Status option reconcile). Matched as the
# EXACT ROOT mutation field (Fix B, below), so the ITEM-value family (`updateProjectV2ItemFieldValue`,
# `clearProjectV2ItemFieldValue`) — which init never runs raw — does NOT qualify for the init carve-out.
_GQL_PROVISION_FIELDS = {"createProjectV2Field", "updateProjectV2Field"}


def _extract_graphql_query(seg_str):
    """Isolate the graphql `query` argument value of a `gh api graphql` SEGMENT (round-8 Fix 1). Returns
    `("literal", <value>)` when a STATIC literal query arg can be isolated, `("opaque", <why>)` when the
    query is present but un-vettable (shell expansion, `@file`, `--input`, or concatenated), or
    `("none", None)` when no query arg is found. ONLY the query arg is inspected — `--jq`/`-q`/other args
    are ignored, so an unrelated `--jq '{…}'` brace can never influence the verdict."""
    if re.search(r"(?<![\w-])--input(?![\w-])", seg_str):
        return ("opaque", "query body supplied via --input file")
    m = _GQL_QUERY_ARG_RE.search(seg_str)
    if not m:
        return ("none", None)
    # Concatenation guard: anything glued to the value (`'query{'"$MUT"'}'`) makes it un-isolatable.
    tail = seg_str[m.end():]
    if tail[:1] and not tail[0].isspace() and tail[0] not in ";|&()<>":
        return ("opaque", "concatenated/continued query value")
    if m.group("sq") is not None:
        return ("literal", m.group("sq"))            # single-quoted → no shell expansion, GraphQL $vars literal
    if m.group("dq") is not None:
        v = m.group("dq")
        if "$" in v or "`" in v:
            return ("opaque", "shell expansion in the query value")
        return ("literal", v)
    bare = m.group("bare")
    if not bare or bare.startswith("@") or "$" in bare or "`" in bare:
        return ("opaque", "file/expansion/empty query value")
    return ("literal", bare)


def _graphql_is_read(seg_str):
    """True iff a `gh api graphql` SEGMENT is a PROVABLE read (round-8 Fix 1): the isolated `query`
    argument value is a STATIC LITERAL whose operation begins (ignoring leading whitespace) with the
    `query` keyword or an anonymous `{ … }` selection AND contains NO `mutation` keyword. Decided on the
    query ARGUMENT ALONE — not the whole command — so a `--jq '{…}'` object elsewhere cannot make an
    opaque `-f query="$MUT"` mutation look readable (the round-7 regression). Fail-closed: an opaque
    query body (shell expansion / `@file` / `--input`), a concatenated value, a `mutation` keyword, or a
    value that cannot be isolated as a static literal all DENY — a mutation can never be smuggled through
    an expansion."""
    style, value = _extract_graphql_query(seg_str)
    if style != "literal":
        return False
    op = value.lstrip()
    if re.search(r"(?<![A-Za-z0-9_])mutation(?![A-Za-z0-9_])", op):
        return False
    return op.startswith("{") or bool(re.match(r"query(?![A-Za-z0-9_])", op))


def _strip_graphql_comments(text):
    """Remove GraphQL line comments (`#` to end of line; GraphQL has no block comments). Used ONLY to
    classify a query as provisioning — an ALLOWANCE — so stripping conservatively (any `#`→EOL, even one
    inside a string literal) is fail-safe: removing text can only make a query look LESS like
    provisioning, never conjure a provisioning ROOT field that wasn't there. This is exactly what closes
    finding-2's comment smuggle (`mutation{closeIssue(…)} # updateProjectV2Field`)."""
    return re.sub(r"#[^\n]*", "", text)


def _graphql_root_mutation_field(query):
    """The ROOT mutation field name of a GraphQL operation LITERAL, or None (round-9 Fix B). Strips
    comments, then (fail-closed) requires a `mutation` operation: skips an optional operation name and
    the variable-definition list `(…)`, finds the selection-set `{`, skips an optional field alias, and
    returns the FIRST field name inside it. A provisioning name appearing only in a COMMENT, an ARGUMENT,
    or a NESTED selection is therefore NOT the root field, so it cannot qualify the query for the init
    carve-out — only the actual executed root mutation does."""
    text = _strip_graphql_comments(query).lstrip()
    if not re.match(r"mutation(?![A-Za-z0-9_])", text):
        return None
    i, n = len(re.match(r"mutation", text).group(0)), len(text)
    while i < n and text[i].isspace():                 # ws before an optional operation name
        i += 1
    mn = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i:])  # optional operation name
    if mn:
        i += mn.end()
    while i < n and text[i].isspace():
        i += 1
    if i < n and text[i] == "(":                        # optional variable definitions — balance parens
        depth = 0
        while i < n:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
    while i < n and text[i].isspace():
        i += 1
    if i >= n or text[i] != "{":                        # selection-set opening brace
        return None
    i += 1
    while i < n and text[i].isspace():
        i += 1
    fm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*(:)?", text[i:])   # first field, or an `alias:`
    if not fm:
        return None
    if fm.group(2):                                     # it was an alias — the real field follows
        i += fm.end()
        while i < n and text[i].isspace():
            i += 1
        fm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", text[i:])
        if not fm:
            return None
    return fm.group(1)


def _graphql_is_provision(seg_str):
    """True iff the `gh api graphql` SEGMENT's isolated query value is a STATIC LITERAL whose ROOT
    mutation field is EXACTLY a sanctioned project-FIELD provisioning mutation
    (`updateProjectV2Field`/`createProjectV2Field`) — the raw op /idc:init runs to reconcile the
    built-in `Status` options (round-9 Fix B). Fail-closed twice over: an OPAQUE query body never
    isolates a literal (stays a plain denied `graphql`), and a sanctioned name that is only a substring
    of a comment/argument/nested selection is NOT the root field, so neither can reach the init
    carve-out."""
    style, value = _extract_graphql_query(seg_str)
    if style != "literal":
        return False
    return _graphql_root_mutation_field(value) in _GQL_PROVISION_FIELDS


def _gh_api_finding(seg_str, endpoint=None):
    """Classify ONE `gh api` SEGMENT bluntly (round-6 Fix 1+2; round-7 Fix 1 for graphql). A `gh api
    graphql` segment is judged on its OPERATION — a provable read `query{…}` is ALLOWED; a `mutation`,
    or an opaque query body, DENIES (`_graphql_is_read`). For NON-graphql `gh api`, DENY iff the segment
    BOTH names a protected API path anywhere AND shows ANY write indicator anywhere (a non-GET
    `-X`/`--method` — ALL occurrences scanned — or any body flag); ALLOWED only when provably a pure
    read. Fail-closed: an opaque `--input FILE`, an ambiguous `-X "$M"`, or a trailing `-X DELETE` after
    a decoy `-X GET` all DENY — every real mutation goes through the Python engine doors.

    round-9 Fix A (finding 1): a `gh api` whose ENDPOINT is a shell expansion (`gh api "$EP" …`) cannot
    be statically confirmed to avoid `graphql` / a protected REST path — the blunt path classifier sees
    no literal protected token and would wave it through. When such a dynamic endpoint ALSO carries a
    write indicator, deny BY CONSTRUCTION. A dynamic-endpoint READ stays allowed here (no write
    indicator); a carve-out denies even the read via `_carveout_dynamic_finding`. `endpoint` is the
    token-parsed endpoint positional when available, else detected on the raw string (lex-failure path)."""
    dyn_ep = _is_dynamic_token(endpoint) if endpoint is not None else _raw_dynamic_api_endpoint(seg_str)
    if dyn_ep and _api_write_indicator(seg_str):
        return _dynamic("a `gh api` with a shell-expansion endpoint and a write indicator")
    kind = _api_protected_path_kind(seg_str)
    if not kind:
        return None                                   # no protected path in the segment → allow
    if kind == "graphql":
        # graphql: decide on the operation (read query vs mutation/opaque), not the blunt body flag.
        if _graphql_is_read(seg_str):
            return None                               # a provable read query → allow (doctor/update read)
        # A LITERAL project-FIELD provisioning mutation (`updateProjectV2Field`) gets a distinct kind so
        # the init carve-out can allow init's own Status option-reconcile while every other graphql
        # mutation (issue writes, item-value writes, opaque bodies) stays denied under init too.
        if _graphql_is_provision(seg_str):
            return _mk("a raw project-field provisioning GraphQL mutation", _ENGINE, "project-field-graphql")
        return _mk("a raw GraphQL board/issue mutation", _ENGINE, "graphql")
    if not _api_write_indicator(seg_str):
        return None                                   # provably a pure read → allow (doctor's audit GET)
    if kind == "dep":
        return _mk("a raw issue-dependency REST write (`dependencies/blocked_by`)", _DEP, "dep-write")
    if re.search(r"state[\"']?\s*[=:]\s*[\"']?\s*(?:closed|open)", seg_str, re.I):
        return _mk("an issue-state-writing `gh api` call", _CLOSE, "issue-state")
    return _mk("a raw issue-state/create `gh api` write", _ENGINE, "issue-create-rest")


def _classify_one_segment(seg_str):
    """A Finding for a protected gh operation in ONE raw shell segment (already separator-free), or
    None. Token-classify the segment (gh global flags incl. `--hostname` stripped by _gh_positionals);
    a `gh api` segment goes through the blunt path-and-write-indicator rule. A lex failure (an
    over-split quote) or a non-gh head falls back to the method-independent whole-segment backstop —
    which still catches a combo/api hidden inside a quoted body, always in the safe (deny) direction."""
    try:
        tokens = _lex(seg_str)
    except ValueError:
        return _classify_string_backstop(seg_str)
    pos = _gh_positionals(tokens)
    if pos is None:
        return _classify_string_backstop(seg_str)     # not a `gh …` invocation
    if pos and pos[0] == "api":
        # round-9 Fix A: pass the token-parsed endpoint positional so a shell-expansion endpoint
        # (`gh api "$EP" …`) is judged order-robustly (flags at any level already stripped by pos).
        return _gh_api_finding(seg_str, endpoint=pos[1] if len(pos) >= 2 else None)
    return _combo_subject(pos)


def _ws_combos(command):
    """Whitespace-flexible `_has` backstop for the gh SUBCOMMAND combos (method-INDEPENDENT, so no
    cross-segment decoy risk) — catches a combo hidden in a body the lexer segmented away (a heredoc /
    an echoed line). Runs AFTER per-segment classification; an over-match only denies in the safe
    direction during an active command (a warning otherwise)."""
    c = command
    if _has(c, "gh pr merge"):
        return _mk("a raw `gh pr merge`", _FINISH, "pr-merge")
    if _has(c, "gh issue create") or _has(c, "gh issue new"):
        return _mk("a raw `gh issue create`", _ENGINE, "issue-create")
    if _has(c, "gh issue close"):
        return _mk("a raw `gh issue close`", _CLOSE, "issue-close")
    if _has(c, "gh issue reopen"):
        return _mk("a raw `gh issue reopen`", _CLOSE, "issue-reopen")
    if _has(c, "gh issue delete"):
        return _mk("a raw `gh issue delete`", _CLOSE, "issue-delete")
    if _has(c, "gh project item-delete"):
        return _mk("a raw `gh project item-delete` board mutation", _ENGINE, "project-item-delete")
    if _has(c, "gh project delete"):
        return _mk("a raw `gh project` board mutation", _ENGINE, "project-delete")
    if _has(c, "gh project item-edit") or _has(c, "gh project item-add"):
        return _mk("a raw `gh project item-{edit,add}` board mutation", _ENGINE, "project-mutation")
    return None


def _classify_string_backstop(seg_str):
    """Whole-SEGMENT fallback for a raw segment that did not token-classify as `gh` (a lex failure from
    an over-split quote, or a combo/`gh api` hidden inside a quoted body). Runs the blunt `gh api` rule
    (only when the segment mentions `gh api`, so a bare `repos/…/issues` string in unrelated text is not
    misread) plus the method-independent combo backstop, on the raw string."""
    if _has(seg_str, "gh api"):
        hit = _gh_api_finding(seg_str)
        if hit:
            return hit
    return _ws_combos(seg_str)


# ── raw newline-aware segmentation (round-6 Fix 1+2) ──────────────────────────────────────────────
# Split the RAW command string on ALL shell separators BEFORE any lexing — this is the blunt, robust
# segmentation the classifier needs: shlex SILENTLY EATS newlines (whitespace), so a token-level split
# never sees a newline separator, and a real `\n`-separated compound looks like one segment. Splitting
# the raw string is quote-UNAWARE on purpose — over-splitting a quoted body only ever creates MORE
# segments to classify (the conservative, fail-closed direction); it can never merge two commands.
_RAW_SEP_RE = re.compile(r"[\n\r;|&]")
# round-7 Fix 2: a shell line-continuation is a backslash IMMEDIATELY followed by a newline — bash
# removes the pair and joins the tokens, so `gh \`+newline+`issue create` runs as `gh issue create`.
# It MUST be collapsed BEFORE segmenting on newlines, or the classifier splits the real command into
# harmless pieces (`gh \` / `issue create`) and waves the write through.
_LINE_CONT_RE = re.compile(r"\\\r?\n")


def _join_line_continuations(command):
    """Collapse `\\`+newline shell line-continuations so a continued command is classified as the one
    command bash actually runs (round-7 Fix 2). Idempotent — no continuation left after one pass."""
    return _LINE_CONT_RE.sub("", command)


def _raw_segments(command):
    """The command's shell segments, split on newlines / `;` / `|` / `&` (covering `&&` and `||` — the
    empty middle piece is dropped). Line-continuations are collapsed FIRST (Fix 2). Blank pieces are
    dropped."""
    return [s for s in _RAW_SEP_RE.split(_join_line_continuations(command)) if s.strip()]


def classify(command):
    """The FIRST Finding for a raw terminal/board command that bypasses the door, or None. The RAW
    command string is segmented on newlines/`;`/`|`/`&` FIRST (Fix 1+2 — shlex would eat the newline),
    then EACH segment is classified on its own tokens, so gh global flags before the subcommand and a
    decoy method flag in another segment cannot bypass the deny; a `gh api` segment is fail-closed
    (allowed only when provably a pure read). Defense-in-depth (a segment-based fail-closed posture),
    NOT a complete shell parser. Under the active-command posture an over-match denies in the safe
    direction; outside an active command it is only a warning."""
    for finding in classify_all(command):
        return finding
    return None


def classify_all(command):
    """EVERY direct protected-op Finding across the raw command's segments (order-preserving, possibly
    empty). The gate uses the full set so the /idc:uninstall carve-out can require EVERY protected
    segment to be a teardown op (round-6 Fix 3), not just the first one classify() returns."""
    return [h for h in (_classify_one_segment(s) for s in _raw_segments(command)) if h]


# ── bounded interpreter inspection (Task 3) ───────────────────────────────────────────────────────
_SEP = {"&&", "||", "|", "|&", ";", "&", "(", ")"}


def _lex(command):
    """Shell-like tokens (quotes respected, operators split out). Raises ValueError on a parse
    failure (e.g. an unbalanced quote) — the caller decides whether that is opaque indirection."""
    lx = shlex.shlex(command, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    return list(lx)


def _segments(tokens):
    """Split a token list into command segments on shell separators (`&&`, `|`, `;`, …), so an
    interpreter invocation anywhere in a compound command is inspected on its own."""
    seg, out = [], []
    for t in tokens:
        if t in _SEP or (t and all(ch in "&|;()<>\n\r" for ch in t)):
            if seg:
                out.append(seg)
                seg = []
        else:
            seg.append(t)
    if seg:
        out.append(seg)
    return out


def _mentions_interpreter_form(command):
    """True iff the raw command text looks like it invokes bash/sh/zsh or a source/`.` form — used to
    decide whether an UNPARSEABLE command is opaque indirection (vs an unrelated quoting quirk)."""
    if re.search(r"(?<![\w./-])(?:bash|sh|zsh|source)(?![\w-])", command):
        return True
    if re.search(r"(?:^|[;&|]\s*)\.\s+\S", command):
        return True
    return False


def _is_sensitive(base):
    """A basename the interlock must NEVER open (rule 6): the ledgered sensitive names, any `*.pem`,
    any `id_rsa*`/`id_dsa*`/`id_ed25519*`, or a name containing `credential`/`secret`."""
    if base in SENSITIVE_BASENAMES:
        return True
    low = base.lower()
    if low.endswith(".pem"):
        return True
    if base.startswith(("id_rsa", "id_dsa", "id_ed25519")):
        return True
    return "credential" in low or "secret" in low


def _opaque(display, why):
    """A refusal for a target the interlock cannot vet — named `opaque-script-indirection`, carrying
    ONLY the normalized display path + the reason (rule 7: never echo script contents)."""
    return Finding(
        f"an opaque interpreter target `{display}` ({why}) the interlock cannot vet "
        "[opaque-script-indirection]", _ENGINE, "opaque-script-indirection")


def _opaque_shell(what):
    """A refusal for a DYNAMIC inline interpreter payload the interlock cannot statically vet — a
    `bash -c`/`env -S` string carrying a shell expansion (`$VAR`/`${…}`/`$(…)`/backtick), or one nested
    past the depth bound (round-8 Fix 2). Named `opaque-shell-indirection`; carries NO payload content."""
    return Finding(f"{what} the interlock cannot statically vet [opaque-shell-indirection]",
                   _ENGINE, "opaque-shell-indirection")


def _has_shell_expansion(payload):
    """True iff an inline interpreter payload contains a shell expansion — `$VAR`, `${…}`, `$(…)`, or a
    backtick. shlex has already stripped the surrounding quotes, so a surviving `$`/backtick means the
    shell WOULD expand it at runtime → the resolved command is opaque (round-8 Fix 2)."""
    return "$" in payload or "`" in payload


# ── round-9 Fix A: fail closed on ANY unresolvable dynamic/opaque construct ────────────────────────
# DEFENSE-IN-DEPTH, FAIL-CLOSED BY CONSTRUCTION (not a complete shell parser). A static classifier can
# never analyze Turing-complete shell, so the remaining bypass class is "hide a protected mutation
# behind a construct the classifier cannot resolve." Rather than chase each variant, we DENY the whole
# call whenever the command carries a dynamic construct that could execute a hidden command or redirect
# an API surface AND cannot be statically confirmed safe: command substitution `$(…)`/backticks,
# process substitution `<(…)`/`>(…)`, a `gh api` with a shell-expansion ENDPOINT, and a
# BASH_ENV/ENV/*ENV/*RC-style startup-file prefix before an interpreter. Under an init/uninstall
# carve-out the bar is absolute — ANY of these deny, because a carve-out allows ops we would otherwise
# deny and its whole safety argument is "every segment is a statically-recognized safe op."
def _dynamic(what):
    """A refusal for an unresolvable DYNAMIC/opaque construct that could hide a protected mutation and
    cannot be statically confirmed safe (round-9 Fix A). Named `dynamic-opaque-indirection`; carries NO
    command content. Its kind is in NO carve-out set, so it denies during ANY active command and — a
    fortiori — under the init/uninstall carve-outs: only fully STATIC recognized ops are ever allowed."""
    return Finding(f"{what} the interlock cannot statically confirm safe [dynamic-opaque-indirection]",
                   _ENGINE, "dynamic-opaque-indirection")


def _is_dynamic_token(tok):
    """True iff a (shlex-dequoted) token carries a shell expansion — a `$` or a backtick. Used to flag a
    `gh api` endpoint positional whose value the shell computes at runtime (`gh api "$EP" …`), which we
    cannot statically confirm is not `graphql` / a protected REST path."""
    return bool(tok) and ("$" in tok or "`" in tok)


def _scan_dynamic_constructs(command):
    """Quote-aware scan for EXECUTING dynamic constructs (round-9 Fix A): command substitution `$(…)`, a
    backtick command substitution, or process substitution `<(…)`/`>(…)`. Returns a short label for the
    FIRST one found, else None. Tracks single-/double-quote state per shell rules — inside single quotes
    `$`, backtick and `(` are all literal (so a single-quoted GraphQL `$var` or `(input:…)` never
    matches); inside double quotes `$(…)` and backticks are still active but process substitution is not.
    A bare `$VAR`/`${VAR}` PARAMETER expansion is deliberately NOT flagged — it interpolates a value, it
    cannot execute a hidden command — so a static provisioning op that uses `$OWNER`/`$PROJ` is allowed."""
    i, n = 0, len(command)
    quote = None                                       # None | "'" | '"'
    while i < n:
        ch = command[i]
        nxt = command[i + 1] if i + 1 < n else ""
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == '"':
                quote = None
            elif ch == "`":
                return "a backtick command substitution"
            elif ch == "$" and nxt == "(":
                return "a command substitution `$(…)`"
            i += 1
            continue
        # unquoted
        if ch == "\\":
            i += 2                                      # a backslash escapes the next char (literal)
            continue
        if ch == "'":
            quote = "'"
        elif ch == '"':
            quote = '"'
        elif ch == "`":
            return "a backtick command substitution"
        elif ch == "$" and nxt == "(":
            return "a command substitution `$(…)`"
        elif ch in "<>" and nxt == "(":
            return "a process substitution `<(…)`/`>(…)`"
        i += 1
    return None


_RAW_DYN_API_EP_RE = re.compile(r"(?<![\w-])api\s+(?:-\S+\s+)*[\"']?[`$]")


def _raw_dynamic_api_endpoint(seg_str):
    """Best-effort (lex-failure fallback) detection that a `gh api` segment's ENDPOINT positional is a
    shell expansion: after `api` and any leading `-flags`, the endpoint token begins with `$`/backtick.
    The token path (`_gh_positionals`) is primary and order-robust; this only backstops a lex failure."""
    return bool(_RAW_DYN_API_EP_RE.search(seg_str))


def _dynamic_gh_api_endpoint(seg_str):
    """True iff a `gh api` SEGMENT's endpoint positional is a shell expansion (round-9 Fix A). Used by
    the carve-out check to deny a dynamic-endpoint `gh api` OUTRIGHT (regardless of write indicator) —
    under a carve-out the endpoint cannot be confirmed static, so it breaks the 'all-static' guarantee."""
    try:
        tokens = _lex(seg_str)
    except ValueError:
        return _raw_dynamic_api_endpoint(seg_str)
    pos = _gh_positionals(tokens)
    return bool(pos and pos[0] == "api" and len(pos) >= 2 and _is_dynamic_token(pos[1]))


def _carveout_dynamic_finding(command):
    """A `dynamic-opaque-indirection` Finding when a command running UNDER an init/uninstall carve-out
    contains ANY unresolvable dynamic construct that breaks the carve-out's 'every segment is a
    statically-recognized safe op' guarantee (round-9 Fix A) — else None. A carve-out ALLOWS ops we
    would otherwise deny (teardown / provisioning), so a construct that could execute a hidden command
    beside the allowed op (`$(…)`/backticks/`<(…)`) or redirect an API surface (a `gh api` with a
    shell-expansion endpoint) is fatal: only FULLY STATIC recognized ops are allowed."""
    what = _scan_dynamic_constructs(command)
    if what is not None:
        return _dynamic(what)
    for seg in _raw_segments(command):
        if _dynamic_gh_api_endpoint(seg):
            return _dynamic("a `gh api` with a shell-expansion endpoint")
    return None


# Env vars a NON-interactive interpreter SOURCES before running its payload/script — bash reads
# $BASH_ENV, sh reads $ENV; SHELLOPTS/BASHOPTS/*ENV/*RC-style names likewise inject startup behavior. A
# prefix assignment to one of these, before an interpreter head, points the shell at a file we cannot
# statically confirm safe (finding 4: `BASH_ENV=fire_gate.sh bash -c 'echo hi'` sources fire_gate.sh —
# with its protected `gh issue create` — BEFORE the innocuous `-c` payload the classifier inspects).
_STARTUP_ENV_RE = re.compile(r"^(?:BASH_ENV|ENV|SHELLOPTS|BASHOPTS|[A-Za-z_][A-Za-z0-9_]*(?:ENV|RC))=(.*)$")


def _startup_env_prefix(seg):
    """The name of a startup-sourcing env var (`BASH_ENV`/`ENV`/`SHELLOPTS`/`*ENV`/`*RC`) assigned a
    NON-EMPTY value as a prefix on `seg` whose interpreter-stripped head is an interpreter — else None.
    Such an assignment sources a file before the interpreter runs its `-c`/script, so it can smuggle a
    protected mutation the payload inspection never sees → fail closed (round-9 Fix A / finding 4). Both
    the bare-prefix (`BASH_ENV=x bash …`) and `env`-wrapped (`env BASH_ENV=x bash …`) forms are covered:
    the prefix region is every token before the interpreter head that `_strip_prefixes` peels off."""
    head_seg = _strip_prefixes(seg)
    if not head_seg or os.path.basename(head_seg[0]) not in INTERPRETERS:
        return None
    prefix_len = len(seg) - len(head_seg)              # the assignment/wrapper tokens peeled before the head
    for tok in seg[:prefix_len]:
        m = _STARTUP_ENV_RE.match(tok)
        if m and m.group(1) != "":                    # an empty value just CLEARS the var → inert
            return tok.split("=", 1)[0]
    return None


def _inspect_target(target, cwd, plugin_root, depth, seen):
    """Resolve+vet a `bash|sh|zsh FILE` / `source FILE` / `. FILE` script target (rules 4–7).

    round-6 Fix 4: resolve realpath()/symlinks FIRST, then apply the sensitive-basename, plugin-scripts
    sanctioned, and regular-file/size/cycle checks on the RESOLVED path, and OPEN ONLY the resolved
    path — so a `safe.sh` symlink → `.env` is refused via the sensitive lane WITHOUT being opened, and a
    symlink beneath `plugin_root/scripts/` whose real target is elsewhere is scanned, not waved through.
    Sensitivity is checked on the lexical name TOO (belt-and-braces over-denial): a file aliased with a
    sensitive name is never opened, whichever end carries the name."""
    lexical = target if os.path.isabs(target) else os.path.join(cwd or ".", target)
    lexical = os.path.normpath(lexical)
    real = os.path.realpath(lexical)                  # resolve symlinks FIRST — every check runs on `real`
    display = lexical                                 # rule 7: name the path the caller typed, not content
    # Rule 6: sensitive — refuse WITHOUT reading (before any stat/open touches it). Check BOTH the
    # resolved basename (a symlink → .env) AND the lexical basename (a .env → innocuous alias).
    if _is_sensitive(os.path.basename(real)) or _is_sensitive(os.path.basename(lexical)):
        return [_opaque(display, "a sensitive file the interlock refuses to open")]
    # Rule 5: files whose RESOLVED path is beneath the plugin's own scripts/ dir are sanctioned — do not
    # scan their bodies. Resolving first means a symlink placed under scripts/ can no longer smuggle an
    # unscanned external target through the sanctioned carve-out.
    if plugin_root:
        scripts_dir = os.path.normpath(os.path.realpath(os.path.join(plugin_root, "scripts")))
        if real == scripts_dir or real.startswith(scripts_dir + os.sep):
            return []
    # cycle + depth guards (rule 6): a self/mutually-including script, or nesting past the bound.
    if real in seen:
        return [_opaque(display, "a cyclic include")]
    if depth + 1 > MAX_SCRIPT_DEPTH:
        return [_opaque(display, "include depth exhausted")]
    # follow REGULAR files only (rule 4), on the RESOLVED path; missing / non-regular / unreadable /
    # too-large → opaque. Open ONLY `real`.
    if not os.path.isfile(real):
        return [_opaque(display, "not a readable regular file")]
    try:
        if os.path.getsize(real) > MAX_SCRIPT_BYTES:
            return [_opaque(display, f"larger than {MAX_SCRIPT_BYTES} bytes")]
        with open(real, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read(MAX_SCRIPT_BYTES + 1)
    except OSError:
        return [_opaque(display, "unreadable")]
    # Collect EVERY protected op reachable inside the script body (round-6 Fix 3: a compound hidden in
    # a FILE — `gh issue close; gh issue create` — must surface ALL segments so the uninstall carve-out
    # can require every one to be a teardown op, not just the first). Each is wrapped with the
    # indirection path (rule 7: path only, never the script body), keeping its op `kind`.
    return [Finding(f"{inner.subject}, reached indirectly via `{display}`", inner.remediation,
                    "script-indirection", inner.kind)
            for inner in collect_findings(body, cwd, plugin_root, depth + 1, seen | {real})]


_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Wrapper words that precede (and do not hide) the real interpreter: `env`/`command`/`builtin`/`exec`.
_CMD_PREFIXES = {"env", "command", "builtin", "exec"}
# Per-wrapper SHORT options that CONSUME a following value token — so `env -u NAME bash f.sh` and
# `exec -a NAME bash f.sh` skip the value too, reaching the real interpreter. Long `--opt=val` forms are
# self-contained single tokens; `--unset NAME`/`--chdir DIR` (space form) consume the next token.
_WRAPPER_VALUE_OPTS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "exec": {"-a"},
    "command": set(),
    "builtin": set(),
}


def _skip_wrapper_opts(seg, i, wrapper):
    """Advance past a wrapper's OPTIONS (and, for `env`, any interleaved `VAR=val` assignments) so the
    real interpreter head is reached (Fix 4). `env -i`/`-u NAME`/`-C DIR`/`-0`/`--`, `command -p`/`-v`,
    `exec -a NAME`, etc. must not stop the strip at the wrapper's first option (which reopened the
    `env -i bash f.sh` / `command -p bash f.sh` script-indirection bypass)."""
    value_opts = _WRAPPER_VALUE_OPTS.get(wrapper, set())
    while i < len(seg):
        tok = seg[i]
        if tok == "--":                                   # end of options
            return i + 1
        if tok.startswith("-") and len(tok) > 1:
            if tok.startswith("--") and "=" in tok:       # `--unset=NAME` — self-contained
                i += 1
            elif tok in value_opts and i + 1 < len(seg):  # `-u NAME` / `--chdir DIR` — consume the value
                i += 2
            else:                                         # bare/combined flag (`-i`, `-pv`, `-Ctmp`)
                i += 1
            continue
        if wrapper == "env" and _ASSIGN_RE.match(tok):    # `env -i A=1 bash f.sh`
            i += 1
            continue
        break
    return i


def _strip_prefixes(seg):
    """Drop leading `VAR=val` assignments and `env`/`command`/`builtin`/`exec` wrapper words TOGETHER
    WITH their options so the REAL interpreter head is seen (`X=1 bash f.sh`, `env -i bash f.sh`,
    `command -p bash f.sh` must all inspect `f.sh`, not wave the wrapper/option through as a benign
    head token). Chained wrappers (`env -i command bash f.sh`) unwind one layer per outer-loop pass."""
    i = 0
    while i < len(seg):
        tok = seg[i]
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        base = os.path.basename(tok)
        if base in _CMD_PREFIXES:
            i = _skip_wrapper_opts(seg, i + 1, base)
            continue
        break
    return seg[i:]


def _env_split_payload(seg):
    """If `seg` is `env … -S/--split-string STRING …` (space form, combined `-Sstring`, or
    `--split-string=string`), return the FULL command line `env` re-parses and executes: the split
    STRING followed by any TRAILING args appended after it — `env -S 'gh issue' create --title x`
    reconstructs `gh issue create --title x` (env splits `-S`'s string into words, then appends the
    remaining argv). It is inspected recursively (like a `bash -c` payload), so an interpreter hidden
    inside the split-string is followed THROUGH instead of consumed as an opaque wrapper value (round-5
    Fix 1: dropping the trailing args reopened `env -S 'gh issue' create …`). Else None."""
    i = 0
    while i < len(seg) and _ASSIGN_RE.match(seg[i]):     # skip leading VAR=val
        i += 1
    if i >= len(seg) or os.path.basename(seg[i]) != "env":
        return None
    i += 1
    while i < len(seg):
        tok = seg[i]
        val, rest = None, []
        if tok in ("-S", "--split-string") and i + 1 < len(seg):
            val, rest = seg[i + 1], seg[i + 2:]
        elif tok.startswith("--split-string="):
            val, rest = tok[len("--split-string="):], seg[i + 1:]
        elif tok.startswith("-S") and not tok.startswith("--") and len(tok) > 2:
            val, rest = tok[2:], seg[i + 1:]
        if val is not None:
            return " ".join([val, *rest]) if rest else val
        i += 1
    return None


def _inspect_segment(seg, cwd, plugin_root, depth, seen):
    """List of findings for one command segment's interpreter/source invocation (rules 3–4)."""
    # round-9 Fix A (finding 4): a BASH_ENV/ENV/SHELLOPTS/*ENV/*RC startup-file prefix before an
    # interpreter head sources that file BEFORE the interpreter runs its `-c`/script, so it can smuggle
    # a protected mutation the payload inspection never sees. Fail closed — deny WITHOUT resolving the
    # (often dynamic) referenced path.
    startup = _startup_env_prefix(seg)
    if startup is not None:
        return [_dynamic(f"a `{startup}=…` startup-file prefix before an interpreter")]
    # `env -S "<string>"` / `--split-string`: the embedded string IS the command — parse it recursively
    # (Fix 1), so an interpreter hidden inside the split-string is not waved through as an opaque value.
    # round-8 Fix 2: a DYNAMIC split-string (any shell expansion) or one nested past the depth bound
    # fails closed — its resolved command is opaque.
    payload = _env_split_payload(seg)
    if payload is not None:
        if _has_shell_expansion(payload):
            return [_opaque_shell("a dynamic `env -S` payload")]
        if depth + 1 > MAX_SCRIPT_DEPTH:
            return [_opaque_shell(f"an `env -S` payload nested past depth {MAX_SCRIPT_DEPTH}")]
        return collect_findings(payload, cwd, plugin_root, depth + 1, seen)
    seg = _strip_prefixes(seg)
    if not seg:
        return []
    head = os.path.basename(seg[0])
    if head in INTERPRETERS:
        args = seg[1:]
        # Rule 3: a quoted `-c PAYLOAD` is the whole command — recurse into it ONLY when it is a fully
        # STATIC literal. round-8 Fix 2: `bash -c "$CMD"` recursed on the literal token `$CMD`, found
        # nothing, and allowed — while the shell expands it to a real mutation. A payload carrying ANY
        # shell expansion, or one nested past the depth bound, now fails closed as opaque-shell-indirection.
        for i, a in enumerate(args):
            if a == "-c" and i + 1 < len(args):
                inline = args[i + 1]
                if _has_shell_expansion(inline):
                    return [_opaque_shell(f"a dynamic `{head} -c` payload")]
                if depth + 1 > MAX_SCRIPT_DEPTH:
                    return [_opaque_shell(f"a `{head} -c` payload nested past depth {MAX_SCRIPT_DEPTH}")]
                return collect_findings(inline, cwd, plugin_root, depth + 1, seen)
        # Rule 4: `bash|sh|zsh FILE` — the first non-flag argument is the script target.
        target = next((a for a in args if not a.startswith("-")), None)
        if target:
            return _inspect_target(target, cwd, plugin_root, depth, seen)
        return []
    if seg[0] in ("source", ".") and len(seg) >= 2:
        return _inspect_target(seg[1], cwd, plugin_root, depth, seen)
    return []


def collect_findings(command, cwd, plugin_root, depth=0, seen=None):
    """EVERY protected-op Finding reachable from `command` — direct per-segment (classify_all) AND
    through interpreter indirection (`bash -c` payloads, `env -S` strings, resolved interpreter/source
    FILEs). Order-preserving, possibly empty. The gate uses the FULL set so the /idc:uninstall carve-out
    can require EVERY protected segment (including ones smuggled after an allowed teardown, or hidden in
    a script body) to be a teardown op (round-6 Fix 3), not just the first one classify() returns."""
    if seen is None:
        seen = frozenset()
    out = []
    if not command or not command.strip():
        return out
    # round-7 Fix 2: collapse `\`+newline line-continuations FIRST, so BOTH the direct per-segment
    # classifier AND the token-level indirection inspection (`_lex`, stdin targets, `bash -c` payloads)
    # see the single command bash actually runs, not the pre-join fragments.
    command = _join_line_continuations(command)
    # Rule 1: the direct per-segment protected-operation classifier (all segments).
    out.extend(classify_all(command))
    # Rule 2: tokenize; a parse failure is opaque ONLY when the command invokes an interpreter form.
    try:
        tokens = _lex(command)
    except ValueError:
        if _mentions_interpreter_form(command):
            out.append(Finding("an opaque shell command the interlock could not parse "
                               "[opaque-shell-indirection]", _ENGINE, "opaque-shell-indirection"))
        return out
    # Redirected script stdin (round-5 Fix 1): `bash|sh|zsh [flags] < FILE` runs FILE as its script —
    # `<` splits segments, so detect the redirect here and inspect FILE like `bash FILE`.
    for target in _stdin_script_targets(tokens):
        out.extend(_inspect_target(target, cwd, plugin_root, depth, seen))
    # Rules 3–4: interpreter `-c` payloads and bash|sh|zsh|source|. FILE targets.
    for seg in _segments(tokens):
        out.extend(_inspect_segment(seg, cwd, plugin_root, depth, seen))
    return out


def inspect_command(command, cwd, plugin_root, depth=0, seen=None):
    """The indirection-aware classifier: the FIRST Finding for a protected operation reachable from
    `command` (directly, via a bash -c payload, or inside a resolved interpreter/source FILE), else
    None — the single-finding view over collect_findings()."""
    for finding in collect_findings(command, cwd, plugin_root, depth, seen):
        return finding
    return None


def _stdin_script_targets(tokens):
    """FILE(s) fed to an interpreter via redirected stdin — `bash|sh|zsh [flags] < FILE`. `<` is a
    segment separator, so the interpreter head and the file land in different segments; recover the
    pairing at the token level. Returns each redirected FILE whose segment head (prefixes stripped)
    is an interpreter."""
    out = []
    for i, tok in enumerate(tokens):
        if tok != "<" or i + 1 >= len(tokens):
            continue
        k, left = i - 1, []
        while k >= 0 and tokens[k] not in _SEP and not (tokens[k] and all(ch in "&|;()<>\n\r" for ch in tokens[k])):
            left.insert(0, tokens[k])
            k -= 1
        left = _strip_prefixes(left)
        if left and os.path.basename(left[0]) in INTERPRETERS:
            out.append(tokens[i + 1])
    return out


def render_reason(finding, plugin_root=""):
    """The model-visible remediation string (a deny reason, or a warn line). Interpolates the REAL
    plugin root the gate received (argv) into the remediation so the recovery command is runnable —
    `${CLAUDE_PLUGIN_ROOT}` text-substitutes only in command/agent/skill markdown, NOT in a Bash
    env (Fix 6), so a literal token emitted from Python would resolve to `/scripts/idc_*.py`."""
    remediation = finding.remediation
    if plugin_root:
        remediation = remediation.replace("${CLAUDE_PLUGIN_ROOT}", plugin_root)
    return (
        f"IDC interlock: {finding.subject} bypasses the single write door (the 394ec6fe "
        f"hand-rolled-finish / loose-improvisation class). Do not run it by hand — {remediation}"
    )


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        H.pre_tool_allow()
    if payload.get("tool_name") != "Bash":
        H.pre_tool_allow()
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip():
        H.pre_tool_allow()

    # Collect EVERY protected op reachable from the command (direct + through indirection) so the
    # uninstall carve-out can judge ALL of them, not just the first (round-6 Fix 3).
    findings = collect_findings(command, cwd, plugin_root)
    if not findings:
        H.pre_tool_allow()
    # POSTURE: hard deny while the session owns an ACTIVE /idc:* command; warn otherwise. The deny
    # honors IDC_HOOKS_OBSERVE_ONLY=1 (the ONE debug escape) inside pre_tool_deny().
    active = L.active_commands(cwd, session_id=payload.get("session_id"))
    finding = findings[0]
    # Command-keyed lifecycle carve-outs (a command may perform its OWN declared lifecycle/provisioning
    # operations — the ops that have no engine door): /idc:uninstall owns TEARDOWN (issue close,
    # project/board delete, item delete); /idc:init owns board PROVISIONING (field creation, repo link,
    # the Status option-reconcile GraphQL mutation). Each is ALLOWED ONLY while THAT command is active,
    # and ONLY when EVERY protected segment of the call is one of the ops that command legitimately owns —
    # a single foreign mutation smuggled alongside (`gh issue close 5 && gh issue create …`, or one hidden
    # in a `bash -c`/script body) DENIES the whole call (round-6 Fix 3). The same ops under any OTHER
    # command, and every other protected mutation under this one, stay denied.
    carve = None
    if any(c.get("command") == "uninstall" for c in active):
        carve = _UNINSTALL_TEARDOWN_KINDS
    elif any(c.get("command") == "init" for c in active):
        carve = _INIT_PROVISION_KINDS
    if carve is not None:
        # round-9 Fix A: a carve-out allows ONLY fully STATIC recognized ops. ANY unresolvable dynamic
        # construct beside the allowed teardown/provisioning op — command substitution `$(…)`/backticks,
        # process substitution `<(…)`/`>(…)`, or a `gh api` with a shell-expansion endpoint — could
        # execute a hidden protected mutation, so it denies the whole call BY CONSTRUCTION, even when the
        # outer op is one the command legitimately owns (finding 3). A startup-file prefix / dynamic
        # write-endpoint already surfaces as a `dynamic-opaque-indirection` finding (never in `carve`).
        dyn = _carveout_dynamic_finding(command)
        offenders = [dyn] if dyn is not None else [f for f in findings if f.kind not in carve]
        if not offenders:
            H.pre_tool_allow()               # every protected segment is this command's own STATIC op → allow
        finding = offenders[0]               # a foreign mutation / dynamic construct rode along → deny naming IT
    reason = render_reason(finding, plugin_root)
    if active:
        H.pre_tool_deny(reason)
    H.pre_tool_warn(reason)       # non-active governed work: warn-inject, never blocks


# The gh teardown ops /idc:uninstall legitimately owns (uninstall.md Phase 4): close IDC issues,
# delete the board/project, delete board items. NOT issue create/delete, pr merge, dependency writes,
# graphql, or item-add/item-edit — none of which uninstall performs.
_UNINSTALL_TEARDOWN_KINDS = {"issue-close", "project-delete", "project-item-delete"}

# The board-provisioning ops /idc:init legitimately owns (init.md Phase 4): create the v2 fields
# (`gh project field-create`), link the board to the repo (`gh project link`), and the Status
# option-reconcile GraphQL mutation (`updateProjectV2Field`, tagged `project-field-graphql`). NOT
# item-add/item-edit/item-delete, project delete, issue/pr writes, dependency writes, or issue/item
# graphql mutations — none of which init performs raw (the Stage-option append routes through
# idc_stage_options.py). A command may perform its own declared provisioning operations.
_INIT_PROVISION_KINDS = {"project-field-create", "project-link", "project-field-graphql"}


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
