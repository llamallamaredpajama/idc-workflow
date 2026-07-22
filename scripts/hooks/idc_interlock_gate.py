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

POSTURE (U4 shared Path Gate): the core always computes the same allow/deny decision, then observes
would-be denials when `pathway_enforcement.mode` is `off` (the scaffold default) and hard-denies only
in `controlled` or `app-locked`. IDC_HOOKS_OBSERVE_ONLY=1 independently forces observe in every mode.
There are no command-name exceptions: Init and Uninstall lifecycle writes run through validating
tracker-adapter helpers, while the same raw GitHub operations are would-be denials when typed directly
into Bash.

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
execute a hidden command or redirect an API surface and cannot be statically confirmed safe — a
`gh api` with a shell-expansion endpoint and a write indicator, a
`BASH_ENV`/`ENV`/`SHELLOPTS`/`*ENV`/`*RC` startup-file prefix before an interpreter, an opaque privilege
wrapper around an interpreter, and a dynamic interpreter/`-c`/`env -S` target. This is
defense-in-depth, not a complete shell parser; a bare `$VAR` parameter expansion (a value, not an
executed command) is deliberately never flagged.

Why this NEVER fires on the sanctioned path: the engine + finishers run `gh` via python subprocess,
NOT via the Bash tool, so PreToolUse never sees them; and a `python3 …/idc_transition.py …` /
`python3 …/idc_pr_finish.py …` Bash call does not invoke an interpreter FILE form and matches no
classifier pattern. Only a RAW terminal command (or one hidden behind interpreter indirection)
matches.

Invocation: idc_interlock_gate.py <PLUGIN_ROOT>   (PreToolUse payload on stdin).
Self-gated: no-op (allow) outside a governed repo, or on a tool/payload the shared Path Gate does not
recognize.
"""
import dataclasses
import os
import re
import shlex
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.dirname(_HERE))
import idc_hook_lib as H  # noqa: E402
import idc_ledger as L    # noqa: E402  (kept for the public Task-3 contract context)
import idc_path_gate as PG  # noqa: E402

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


@dataclasses.dataclass(frozen=True)
class _Finding:
    """Private classifier record. Policy tags stay private; the public Finding contract is exact."""
    subject: str
    remediation: str
    source: str
    kind: str = ""


def _mk(subject, remediation, kind):
    """A direct-classifier Finding carrying its op `kind` (source is always the direct classifier)."""
    return _Finding(subject, remediation, "direct", kind)


def _public(finding):
    """Project an internal tagged finding onto the exact three-field public contract."""
    if finding is None or isinstance(finding, Finding):
        return finding
    return Finding(finding.subject, finding.remediation, finding.source)


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
_PR_GATE_BIND = (
    "bind a Think PR and its requirements-change gate through the reciprocal marker door: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_pr_gate_bind.py --repo <repo> --pr <N> "
    "--gate <M>` — it validates both existing bodies before writing, refuses mismatches, and reads "
    "each marker back. Raw `gh pr edit` remains denied."
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
    | {("project", v) for v in ("create", "item-add", "item-edit", "item-delete", "item-archive",
                                "field-create", "edit", "delete", "copy", "link", "unlink")}
)
def _gh_positionals(seg):
    """The POSITIONAL word sequence of a `gh …` command SEGMENT — known execution prefixes and options
    at any gh level stripped — or None when the real command head is not `gh`. `gh issue -R o/r create`
    becomes `['issue', 'create']`. Requiring the actual normalized head keeps literal documentation text
    passed to `grep`/`echo`/`printf` from being mistaken for an executed mutation; interpreter payloads
    and script files are inspected separately by the bounded indirection path."""
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
    combo, else None. The private `kind` keeps diagnostic detail out of the exact public contract."""
    if not pos:
        return None
    # round-11 Fix 2: when the SUBCOMMAND (noun) or the operation (verb) token is a shell expansion
    # (`gh issue "$op"` / `gh "$sub" merge`), its read-vs-write nature cannot be statically resolved →
    # FAIL CLOSED during any active command. A dynamic ARGUMENT (`gh issue view "$num"`) is NOT
    # flagged — only the noun/verb decide read-vs-write, so a static-read subcommand stays allowed.
    if _is_dynamic_token(pos[0]) or (len(pos) >= 2 and _is_dynamic_token(pos[1])):
        return _dynamic("a `gh` invocation whose subcommand is computed by a shell expansion")
    if len(pos) < 2:
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
        remediation = _PR_GATE_BIND if verb == "edit" else _FINISH
        return _mk(f"a raw `gh pr {verb}`", remediation,
                   "pr-merge" if verb == "merge" else f"pr-{verb}")
    # Keep distinct private kinds for precise diagnostics; policy denies every protected combo.
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
    write indicator, deny BY CONSTRUCTION. A dynamic-endpoint READ stays allowed because it carries
    no write indicator. `endpoint` is the token-parsed endpoint positional when available, else
    detected on the raw string (lex-failure path)."""
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
    a `gh api` segment goes through the blunt path-and-write-indicator rule. A lex failure falls back to
    the conservative whole-segment matcher. A successfully parsed non-gh command is data/another tool,
    not a raw gh invocation; bounded interpreter and script inspection runs separately."""
    try:
        tokens = _lex(seg_str)
    except ValueError:
        return _classify_string_backstop(seg_str)
    pos = _gh_positionals(tokens)
    if pos is None:
        return None                                   # protected words may be literal data for another tool
    if pos and pos[0] == "api":
        # round-9 Fix A: pass the token-parsed endpoint positional so a shell-expansion endpoint
        # (`gh api "$EP" …`) is judged order-robustly (flags at any level already stripped by pos).
        return _gh_api_finding(seg_str, endpoint=pos[1] if len(pos) >= 2 else None)
    return _combo_subject(pos)


def _ws_combos(command):
    """Whitespace-flexible gh-subcommand backstop for an unparseable shell segment. Parsed segments use
    the real normalized command head, so literal command examples passed to another tool stay data."""
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
    if _has(c, "gh issue edit"):
        return _mk("a raw `gh issue edit`", _ENGINE, "issue-edit")
    if _has(c, "gh pr close"):
        return _mk("a raw `gh pr close`", _FINISH, "pr-close")
    if _has(c, "gh pr edit"):
        return _mk("a raw `gh pr edit`", _PR_GATE_BIND, "pr-edit")
    if _has(c, "gh project item-delete"):
        return _mk("a raw `gh project item-delete` board mutation", _ENGINE, "project-item-delete")
    if _has(c, "gh project create"):
        return _mk("a raw `gh project create` board mutation", _ENGINE, "project-create")
    if _has(c, "gh project field-create"):
        return _mk("a raw `gh project field-create` board mutation", _ENGINE, "project-field-create")
    if _has(c, "gh project link"):
        return _mk("a raw `gh project link` board mutation", _ENGINE, "project-link")
    if _has(c, "gh project delete"):
        return _mk("a raw `gh project` board mutation", _ENGINE, "project-delete")
    if _has(c, "gh project item-edit") or _has(c, "gh project item-add"):
        return _mk("a raw `gh project item-{edit,add}` board mutation", _ENGINE, "project-mutation")
    return None


def _classify_string_backstop(seg_str):
    """Conservative whole-segment fallback when shell tokenization fails. Runs the blunt `gh api` rule
    only when the segment names `gh api`, then the method-independent combo matcher."""
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


# Chars after which a `#` begins a new word (so `#` there opens a shell comment): the start of the
# string, whitespace, or a shell metacharacter. A `#` glued to a word (`foo#bar`, `$(cmd)#`) is literal.
_WORD_BOUNDARY_CHARS = set(" \t\n\r;|&()<>")


def _strip_shell_comments(command):
    r"""Remove shell comments QUOTE-AWARE, matching bash (round-11 Fix 1). A `#` begins a comment ONLY
    when it starts a word — at string start, or right after unquoted whitespace / a shell metacharacter
    (`;|&()<>`) — and NOT inside single/double quotes and NOT escaped; from there to (not incl.) the
    newline is discarded. A `#` mid-word (`foo#bar`) or inside quotes (`-f query='…#…'`) is literal and
    kept. This is fail-safe for the classifier: it exactly mirrors bash's own comment rule, so it never
    strips text bash WOULD execute (no bypass) and it removes the comment text the classifier must not
    read as executable (init.md/update.md's `# … gh api graphql -f query="$MUT" …` reconcile notes).
    MUST run BEFORE line-continuation joining: a `\`+newline INSIDE a comment is literal to bash (not a
    continuation), so joining first could pull a following real command up into the stripped comment."""
    out = []
    quote = None                                   # None | "'" | '"'
    at_boundary = True                             # start of string is a word boundary
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            out.append(ch)
            if ch == "'":
                quote = None
            at_boundary = False
            i += 1
            continue
        if quote == '"':
            out.append(ch)
            if ch == "\\" and i + 1 < n:           # inside "…", a backslash escapes the next char
                out.append(command[i + 1])
                i += 2
                continue
            if ch == '"':
                quote = None
            at_boundary = False
            i += 1
            continue
        # unquoted
        if ch == "\\":                             # a backslash escapes the next char (incl. a newline)
            out.append(ch)
            if i + 1 < n:
                out.append(command[i + 1])
                i += 2
            else:
                i += 1
            at_boundary = False
            continue
        if ch == "#" and at_boundary:
            while i < n and command[i] not in "\n\r":   # discard to end of line (keep the newline)
                i += 1
            at_boundary = True
            continue
        out.append(ch)
        if ch == "'":
            quote = "'"
            at_boundary = False
        elif ch == '"':
            quote = '"'
            at_boundary = False
        else:
            at_boundary = ch in _WORD_BOUNDARY_CHARS
        i += 1
    return "".join(out)


def _raw_segments(command):
    """The command's shell segments, split on newlines / `;` / `|` / `&` (covering `&&` and `||` — the
    empty middle piece is dropped). Line-continuations are collapsed FIRST (Fix 2). Blank pieces are
    dropped."""
    return [s for s in _RAW_SEP_RE.split(_join_line_continuations(command)) if s.strip()]


def classify_all(command):
    """EVERY direct protected-op Finding across the raw command's segments (order-preserving, possibly
    empty). The full set preserves compounds and every write hidden behind script indirection."""
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
    return _Finding(
        f"an opaque interpreter target `{display}` ({why}) the interlock cannot vet "
        "[opaque-script-indirection]", _ENGINE, "opaque-script-indirection")


def _opaque_shell(what):
    """A refusal for a DYNAMIC inline interpreter payload the interlock cannot statically vet — a
    `bash -c`/`env -S` string carrying a shell expansion (`$VAR`/`${…}`/`$(…)`/backtick), or one nested
    past the depth bound (round-8 Fix 2). Named `opaque-shell-indirection`; carries NO payload content."""
    return _Finding(f"{what} the interlock cannot statically vet [opaque-shell-indirection]",
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
# an API surface AND cannot be statically confirmed safe: a `gh api` with a shell-expansion endpoint
# plus a write indicator, a startup-file prefix before an interpreter, or an opaque interpreter hidden
# behind a privilege wrapper.
def _dynamic(what):
    """A refusal for an unresolvable DYNAMIC/opaque construct that could hide a protected mutation and
    cannot be statically confirmed safe (round-9 Fix A). Named `dynamic-opaque-indirection`; carries NO
    command content. It denies during any active IDC command."""
    return _Finding(f"{what} the interlock cannot statically confirm safe [dynamic-opaque-indirection]",
                    _ENGINE, "dynamic-opaque-indirection")


def _is_dynamic_token(tok):
    """True iff a (shlex-dequoted) token carries a shell expansion — a `$` or a backtick. Used to flag a
    `gh api` endpoint positional whose value the shell computes at runtime (`gh api "$EP" …`), which we
    cannot statically confirm is not `graphql` / a protected REST path."""
    return bool(tok) and ("$" in tok or "`" in tok)


_RAW_DYN_API_EP_RE = re.compile(r"(?<![\w-])api\s+(?:-\S+\s+)*[\"']?[`$]")


def _raw_dynamic_api_endpoint(seg_str):
    """Best-effort (lex-failure fallback) detection that a `gh api` segment's ENDPOINT positional is a
    shell expansion: after `api` and any leading `-flags`, the endpoint token begins with `$`/backtick.
    The token path (`_gh_positionals`) is primary and order-robust; this only backstops a lex failure."""
    return bool(_RAW_DYN_API_EP_RE.search(seg_str))


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
    # unscanned external target through this sanctioned adapter boundary.
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
    # a FILE — `gh issue close; gh issue create` — must surface ALL segments, not just the first).
    # Each is wrapped with the
    # indirection path (rule 7: path only, never the script body), keeping its op `kind`.
    return [_Finding(f"{inner.subject}, reached indirectly via `{display}`", inner.remediation,
                     "script-indirection", inner.kind)
            for inner in collect_findings(body, cwd, plugin_root, depth + 1, seen | {real})]


_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Wrapper words that precede (and do not hide) the real interpreter: `env`/`command`/`builtin`/`exec`.
_CMD_PREFIXES = {"env", "command", "builtin", "exec"}
# Leading shell control words / compound-command keywords a segment can open with WITHOUT changing the
# real command head (round-10 Fix 4): `else gh project link …` runs `gh project link`, not a command
# named `else`. Skipped when locating a segment's head, else `project link`/`field-create` fell through
# the gh classifier and were ALLOWED under Think though they are init-only (init.md:201 uses `else gh
# project link`). Matched as an EXACT leading token (a real command is never literally named `then`).
_CONTROL_WORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case",
                  "esac", "in", "function", "{", "}", "(", ")", "!", "time"}
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


# round-12 Fix 2: GENERIC execution wrappers that PRECEDE the real command and hand off to it, beyond the
# env/command/builtin/exec family above. The gh path is already wrapper-AGNOSTIC (it scans the token
# stream for a bare `gh` head after this strip); the interpreter path detects an EXACT head token, so it
# needs these wrappers stripped HERE — sharing this ONE helper keeps the two paths from drifting (a
# wrapper added here protects both). Each entry lists the wrapper's SHORT/long options that CONSUME the
# next token (`timeout -s SIG`, `stdbuf -o L`, `nice -n 10`, …) and how many leading NUMERIC operands it
# takes before the command word (`timeout DURATION`, `chrt PRIO`, `taskset MASK`). Only a DIGIT-leading
# bare token is eaten as an operand, so an alpha command head (`gh`/`bash`) is never swallowed
# (`timeout gh …` keeps `gh`); a NON-wrapper leading word (`grep bash f`) is not peeled at all.
_EXEC_WRAPPERS = {
    "nohup":   {"value_opts": set(),                                            "operands": 0},
    "setsid":  {"value_opts": set(),                                            "operands": 0},
    "stdbuf":  {"value_opts": {"-i", "-o", "-e", "--input", "--output", "--error"}, "operands": 0},
    "timeout": {"value_opts": {"-s", "--signal", "-k", "--kill-after"},         "operands": 1},
    "nice":    {"value_opts": {"-n", "--adjustment"},                           "operands": 0},
    "ionice":  {"value_opts": {"-c", "--class", "-n", "--classdata", "-p", "--pid"}, "operands": 0},
    "xargs":   {"value_opts": {"-I", "-i", "--replace", "-n", "--max-args", "-P", "--max-procs",
                               "-s", "--max-chars", "-d", "--delimiter", "-E", "-e", "--eof",
                               "-a", "--arg-file", "-L", "--max-lines"},        "operands": 0},
    "chrt":    {"value_opts": {"-p", "--pid"},                                  "operands": 1},
    "taskset": {"value_opts": {"-p", "--pid", "-c", "--cpu-list"},              "operands": 1},
    # Privilege wrappers are execution wrappers too. Their value-taking options must be consumed so
    # `sudo -u root bash FILE` / `doas -u root sh FILE` reach the interpreter instead of stopping at
    # the user name. An unrecognized option layout that still visibly contains an interpreter falls
    # through to the opaque-wrapper refusal in `_inspect_segment` (fail closed, never wave through).
    "sudo":    {"value_opts": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
                                "-C", "--close-from", "-D", "--chdir", "-R", "--chroot",
                                "-r", "--role", "-t", "--type", "-T", "--command-timeout"},
                "operands": 0},
    "doas":    {"value_opts": {"-a", "-C", "-u"},                              "operands": 0},
}
_OPERAND_NUMERIC_RE = re.compile(r"^\+?[0-9]")   # a DIGIT-leading operand (duration/priority/mask), never a command word


def _skip_exec_wrapper(seg, i, spec):
    """Advance past a generic exec wrapper's dashed OPTIONS (value-opts consume the next token) and any
    leading NUMERIC operand(s) so the real command head is reached (round-12 Fix 2). A bare ALPHA token
    stops the strip — it is the command word (or the `gh`/interpreter head), never consumed as an
    operand — so `timeout 5 bash f.sh` peels `timeout 5` but `timeout gh …`/`nohup bash f.sh` keep the
    head. `--` ends option processing; the next token is the command."""
    value_opts = spec["value_opts"]
    operands = spec["operands"]
    while i < len(seg):
        tok = seg[i]
        if tok == "--":                                    # end of options → next token is the command
            return i + 1
        if tok.startswith("-") and len(tok) > 1:
            if tok.startswith("--") and "=" in tok:        # `--signal=KILL` — self-contained
                i += 1
            elif tok in value_opts and i + 1 < len(seg):   # `-s KILL` / `-o L` — consume the value
                i += 2
            else:                                          # bare/combined flag (`-oL`, `-c2`, `-10`)
                i += 1
            continue
        if tok.startswith("+") and len(tok) > 1:           # `+x`-style flag
            i += 1
            continue
        if operands > 0 and _OPERAND_NUMERIC_RE.match(tok):  # `timeout 5` / `chrt 20` / `taskset 0x3`
            operands -= 1
            i += 1
            continue
        break
    return i


def _strip_prefixes(seg):
    """FULL-DESCEND normalization to the REAL command head: drop leading `VAR=val` assignments and
    execution-wrapper words TOGETHER WITH their options (`X=1 bash f.sh`, `env -i bash f.sh`, `command -p
    bash f.sh`, and the generic `nohup`/`timeout 5`/`stdbuf -oL`/`setsid`/`nice -n 10`/… wrappers must all
    reach `f.sh`, not wave the wrapper/option through as a benign head token). `env` is DESCENDED (its
    `-S`/`-u NAME`/`-i` options are consumed). Shared by the gh path (which then scans for a bare `gh`
    head), the startup-env detector, the interpreter/source scan, and the stdin-redirect pairing so they
    stay wrapper-agnostic in lockstep. Chained wrappers (`env -i command bash f.sh`, `nohup timeout 5
    bash f.sh`) unwind one layer per outer-loop pass.

    round-13 Fix 2: `time`/`time -p`/`time --portability` (bash's `time [-p] pipeline` keyword form) peels
    the `time` word AND its optional `-p`/`--portability` flag, so `time -p bash f.sh` / `time -p gh …`
    reach the real interpreter/gh head instead of leaving `-p` dangling as a bogus head token.

    The INSPECT entry (`_inspect_segment`) uses `_peel_to_inspect_head` instead — a sibling fixpoint that
    STOPS at `env` and at a startup-env assignment (both carry a payload) — then this full descend re-peels
    to reach `bash|sh|zsh`."""
    i = 0
    while i < len(seg):
        tok = seg[i]
        if tok == "time":                                  # round-13 Fix 2: `time [-p] pipeline` keyword
            i += 1
            while i < len(seg) and seg[i] in ("-p", "--portability"):
                i += 1
            continue
        if tok in _CONTROL_WORDS:                          # round-10 Fix 4: `else`/`then`/`!`/… head
            i += 1
            continue
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        base = os.path.basename(tok)
        if base in _CMD_PREFIXES:
            i = _skip_wrapper_opts(seg, i + 1, base)
            continue
        if base in _EXEC_WRAPPERS:                         # round-12 Fix 2: generic wrapper-agnostic strip
            i = _skip_exec_wrapper(seg, i + 1, _EXEC_WRAPPERS[base])
            continue
        break
    return seg[i:]


def _peel_to_inspect_head(seg):
    """SINGLE fixpoint prefix-normalization for the inspect entry (round-14): peel the FRONT of a segment
    — control words, `time [-p]`, exec WRAPPERS + their options, and ORDINARY `VAR=val` assignments — in
    ANY interleaving, until the head is the real command, so `_inspect_segment`'s env-split / startup-file
    / interpreter / source checks all run on the TRUE head no matter how wrappers and assignments are
    ordered. This closes the round-13 ordering class by construction: `FOO=1 nohup env -S 'gh issue'
    create` peels `FOO=1 nohup` and stops at `env`, where `_env_split_payload` reconstructs the mutation
    (round-13 stopped the strip at the FIRST leading assignment, so it never peeled the following wrapper).

    Two heads are KEPT (not crossed), because they carry a PAYLOAD the following checks must inspect with
    the head intact:
      * a leading `env` token — `_env_split_payload` and the later full descend handle its `-S`/options;
      * a STARTUP-ENV assignment (`BASH_ENV`/`ENV`/`SHELLOPTS`/`*RC`) — a deny/inspect SIGNAL that
        `_startup_env_prefix` must see, so it is STOPPED-AT, never crossed like an ordinary assignment
        (crossing it would erase the startup-file signal and reopen finding 4 behind a benign prefix).
    Ordinary assignments are CROSSED; chained wrappers unwind one layer per loop pass. `time` is matched
    before the (overlapping) control-word set so its optional `-p`/`--portability` is peeled too."""
    i = 0
    while i < len(seg):
        tok = seg[i]
        if tok == "time":                                  # `time [-p] pipeline` keyword + optional flag
            i += 1
            while i < len(seg) and seg[i] in ("-p", "--portability"):
                i += 1
            continue
        if tok in _CONTROL_WORDS:                          # `else`/`then`/`!`/… leading control word
            i += 1
            continue
        if _ASSIGN_RE.match(tok):
            if _STARTUP_ENV_RE.match(tok):                 # BASH_ENV/ENV/SHELLOPTS/*RC — keep as head (signal)
                break
            i += 1                                         # ordinary VAR=val — CROSS it (round-14)
            continue
        base = os.path.basename(tok)
        if base == "env":                                  # keep `env` as head for env-split / startup inspection
            break
        if base in _CMD_PREFIXES:                          # command/builtin/exec — peel wrapper + its options
            i = _skip_wrapper_opts(seg, i + 1, base)
            continue
        if base in _EXEC_WRAPPERS:                         # nohup/timeout 5/stdbuf -oL/setsid/nice -n 10/…
            i = _skip_exec_wrapper(seg, i + 1, _EXEC_WRAPPERS[base])
            continue
        break                                              # real command head
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


# Interpreter options that NAME A FILE the shell SOURCES (`bash --rcfile`/`--init-file` for an
# interactive shell). Their VALUE is a startup file that must be inspected too — AND consumed, so it is
# not mistaken for the script target (round-11 Fix 3: `bash --rcfile <decoy> <script>` runs <script>, but
# the old "first non-flag arg" picked <decoy> as the script and never inspected <script>).
_INTERP_FILE_OPTS = {"--rcfile", "--init-file"}
# Interpreter options that consume a NON-file value token (a shopt name / `set -o` name) — skip BOTH so
# the real script positional is still found. Over-consuming is safe: in every form where one of these
# would swallow the script, bash treats the script as the option's argument and never runs it as a
# script (e.g. `bash -O foo.sh` errors on an invalid shopt name), so nothing executes to bypass.
_INTERP_VALUE_OPTS = {"-O", "+O", "-o", "+o"}


def _is_dash_c_flag(tok):
    """True if `tok` is bash's `-c` command flag — the bare `-c` OR a combined short-flag cluster whose
    LAST letter is `c` (`-xc`, `-ic`, `-lc`): in a `-<letters>` bundle the trailing `c` means the NEXT
    arg is the command STRING, not a script file (round-12 Fix 3). Restricted to an all-alpha `-<letters>`
    token so a path/number (`-2c`, `-O`) or a long option (`--…`) is never mistaken for it."""
    return (len(tok) >= 2 and tok[0] == "-" and tok[1] != "-"
            and tok[-1] == "c" and all(ch.isalpha() for ch in tok[1:]))


def _interpreter_plan(args):
    """Single left-to-right walk of a `bash|sh|zsh` arg list, returning `(payload, sources, script)`:

      * `payload` — the `-c` COMMAND STRING (recognized as a bare `-c` OR a combined cluster ending in
        `c` per round-12 Fix 3), else None. With `-c`, the following positionals are $0/$1… (NOT a script
        file), so `script` stays None.
      * `sources` — every `--rcfile`/`--init-file` value bash SOURCES at startup, collected even when a
        `-c` payload is present (round-12 Fix 1: no early return — the rcfile is sourced BEFORE the -c
        payload runs, so a mutation hidden in it must still be inspected). Only sources seen BEFORE the
        `-c` are startup files; after `-c` everything is positional, so the walk stops there.
      * `script` — the positional script FILE bash RUNS (the FIRST positional after option processing),
        or None. Value-taking options (`--rcfile FILE`, `-O shopt`, `-o name`, `--`) are consumed so a
        decoy option value cannot masquerade as the script. Script ARGUMENTS after the target are not
        returned — only the first positional is the script."""
    payload, sources, script = None, [], None
    i, n = 0, len(args)
    while i < n:
        tok = args[i]
        if tok == "--":                                      # end of options → next token is the script
            rest = args[i + 1:]
            script = rest[0] if rest else None
            break
        if _is_dash_c_flag(tok):                             # `-c`/`-xc` PAYLOAD — command string, not a file
            if i + 1 < n:
                payload = args[i + 1]
            break                                            # after -c everything is positional; stop
        if "=" in tok and tok.split("=", 1)[0] in _INTERP_FILE_OPTS:   # --rcfile=FILE
            sources.append(tok.split("=", 1)[1])
            i += 1
            continue
        if tok in _INTERP_FILE_OPTS and i + 1 < n:           # --rcfile FILE (space form)
            sources.append(args[i + 1])
            i += 2
            continue
        if tok in _INTERP_VALUE_OPTS and i + 1 < n:          # -O shopt / -o name — consume the value token
            i += 2
            continue
        if tok.startswith("-") or tok.startswith("+"):       # any other bare/self-contained flag
            i += 1
            continue
        script = tok                                         # first non-flag positional = the script
        break
    return payload, sources, script


def _su_command_payload(seg):
    """Return ``(seen_command_flag, payload)`` for BSD/GNU ``su`` command forms.

    Both place ``-c/--command`` either before or after the login name; the long and short joined forms
    are accepted too. A seen flag with no value returns ``(True, None)`` so the caller fails closed.
    """
    for i, tok in enumerate(seg[1:], 1):
        if tok in ("-c", "--command"):
            return True, seg[i + 1] if i + 1 < len(seg) else None
        if tok.startswith("--command="):
            return True, tok.split("=", 1)[1]
        if tok.startswith("-c") and not tok.startswith("--") and len(tok) > 2:
            return True, tok[2:]
    return False, None


def _inspect_su(seg, cwd, plugin_root, depth, seen):
    """Inspect ``su … -c COMMAND`` or an explicit interpreter tail; fail closed if opaque."""
    has_command, payload = _su_command_payload(seg)
    if has_command:
        if not payload or _has_shell_expansion(payload):
            return [_opaque_shell("an opaque `su -c` payload")]
        if depth + 1 > MAX_SCRIPT_DEPTH:
            return [_opaque_shell(f"a `su -c` payload nested past depth {MAX_SCRIPT_DEPTH}")]
        return collect_findings(payload, cwd, plugin_root, depth + 1, seen)

    # Some su implementations pass trailing arguments to the login shell. If an explicit supported
    # interpreter is visible, inspect from that token. If the layout cannot be normalized, the caller's
    # privilege-wrapper fallback refuses it as opaque rather than letting the wrapper hide the file.
    for i, tok in enumerate(seg[1:], 1):
        if os.path.basename(tok) in INTERPRETERS or tok in ("source", "."):
            return _inspect_segment(seg[i:], cwd, plugin_root, depth, seen)
    return []


def _opaque_privilege_interpreter(seg):
    """An opaque sudo/doas/su layout that visibly carries an interpreter, else None."""
    wrapper_i = next((i for i, tok in enumerate(seg)
                      if os.path.basename(tok) in {"sudo", "doas", "su"}), None)
    if wrapper_i is None:
        return None
    if any(os.path.basename(tok) in INTERPRETERS or tok in ("source", ".")
           for tok in seg[wrapper_i + 1:]):
        wrapper = os.path.basename(seg[wrapper_i])
        return _opaque_shell(f"an opaque `{wrapper}` interpreter wrapper")
    return None


def _inspect_segment(seg, cwd, plugin_root, depth, seen):
    """List of findings for one command segment's interpreter/source invocation (rules 3–4)."""
    original_seg = list(seg)
    # round-14: normalize the front with the SINGLE fixpoint peel — cross ordinary `VAR=val` assignments
    # and peel exec wrappers / control words (`nohup`/`timeout 5`/`stdbuf -oL`/`setsid`/`command`/`time -p`/
    # …) in ANY interleaving, stopping only at the real head OR at a leading `env` / startup-env assignment
    # (both carry a PAYLOAD the checks below must inspect with the head intact). Before round-14 the strip
    # stopped at the FIRST leading assignment, so `FOO=1 nohup env -S 'gh issue' create` left `FOO=1` as the
    # head, env-split saw `nohup` (not `env`), and the reconstructed mutation slipped.
    seg = _peel_to_inspect_head(seg)
    if not seg:
        return []
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
    if os.path.basename(seg[0]) == "su":
        return _inspect_su(seg, cwd, plugin_root, depth, seen)
    # `source FILE` / `. FILE` — a shell BUILTIN at the head (never wrapped by nohup/timeout/…), so it is
    # matched on the exact stripped head BEFORE the interpreter scan, so a target literally named `bash`
    # is inspected as a sourced file, not mistaken for an interpreter head.
    if seg[0] in ("source", ".") and len(seg) >= 2:
        return _inspect_target(seg[1], cwd, plugin_root, depth, seen)
    head = os.path.basename(seg[0])
    if head in INTERPRETERS:
        args = seg[1:]
        payload, sources, script = _interpreter_plan(args)
        out = []
        # Rule 3: a quoted `-c PAYLOAD` is a command — recurse ONLY when it is a fully STATIC literal.
        # round-8 Fix 2: `bash -c "$CMD"` recursed on the literal token `$CMD`, found nothing, and
        # allowed — while the shell expands it to a real mutation. A payload carrying ANY shell
        # expansion, or one nested past the depth bound, fails closed as opaque-shell-indirection.
        # round-12 Fix 1: the `-c` payload is combined WITH the sourced/run targets below, not returned
        # early, so a `--rcfile`/`--init-file` that bash SOURCES before the payload is still inspected.
        if payload is not None:
            if _has_shell_expansion(payload):
                out.append(_opaque_shell(f"a dynamic `{head} -c` payload"))
            elif depth + 1 > MAX_SCRIPT_DEPTH:
                out.append(_opaque_shell(f"a `{head} -c` payload nested past depth {MAX_SCRIPT_DEPTH}"))
            else:
                out.extend(collect_findings(payload, cwd, plugin_root, depth + 1, seen))
        # Rule 4: `bash|sh|zsh [opts] FILE` — inspect EVERY path it would SOURCE or RUN (round-11 Fix 3):
        # each `--rcfile`/`--init-file` value AND the script target (found AFTER value-taking options are
        # consumed, so a `--rcfile <decoy>` value can no longer masquerade as the script).
        for target in [*sources, *([script] if script is not None else [])]:
            out.extend(_inspect_target(target, cwd, plugin_root, depth, seen))
        return out
    opaque = _opaque_privilege_interpreter(original_seg)
    return [opaque] if opaque else []


def collect_findings(command, cwd, plugin_root, depth=0, seen=None):
    """EVERY protected-op Finding reachable from `command` — direct per-segment (classify_all) AND
    through interpreter indirection (`bash -c` payloads, `env -S` strings, resolved interpreter/source
    FILEs). Order-preserving, possibly empty. The full set catches every protected segment, including
    writes smuggled after another operation or hidden in a script body."""
    if seen is None:
        seen = frozenset()
    out = []
    if not command or not command.strip():
        return out
    # round-11 Fix 1: strip shell comments QUOTE-AWARE FIRST — before joining line-continuations — so
    # comment TEXT (e.g. init.md/update.md's `# … gh api graphql -f query="$MUT" …` reconcile notes) is
    # never classified as executable, and a `\`+newline inside a comment (literal to bash) cannot pull a
    # following real command up into the stripped region. Applied here so it covers direct classification
    # AND every recursive path (script bodies, inner substitutions) that routes through collect_findings.
    command = _strip_shell_comments(command)
    # round-7 Fix 2: collapse `\`+newline line-continuations, so BOTH the direct per-segment classifier
    # AND the token-level indirection inspection (`_lex`, stdin targets, `bash -c` payloads) see the
    # single command bash actually runs, not the pre-join fragments.
    command = _join_line_continuations(command)
    # Rule 1: the direct per-segment protected-operation classifier (all segments).
    out.extend(classify_all(command))
    # Rule 2: tokenize; a parse failure is opaque ONLY when the command invokes an interpreter form.
    try:
        tokens = _lex(command)
    except ValueError:
        if _mentions_interpreter_form(command):
            out.append(_Finding("an opaque shell command the interlock could not parse "
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
        return _public(finding)
    return None


def classify(command, cwd, plugin_root, active):
    """Public Task-3 contract: classify one Bash command in its repo/session context.

    ``active`` remains part of the compatibility interface, but classification is posture-independent;
    the shared Path Gate applies the configured observe-versus-enforce posture after classification.
    """
    _ = bool(active)  # normalize truthiness without changing warn-vs-deny classification
    return inspect_command(command, cwd, plugin_root)


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


@dataclasses.dataclass
class _ShellGateAnalysis:
    paths: list[str] = dataclasses.field(default_factory=list)
    deny_reason: str | None = None

    def add_paths(self, paths):
        for item in paths:
            if item and item not in self.paths:
                self.paths.append(item)

    def deny(self, reason):
        if reason and not self.deny_reason:
            self.deny_reason = reason

    def merge(self, other):
        if other is None:
            return
        self.add_paths(getattr(other, "paths", []))
        self.deny(getattr(other, "deny_reason", None))


_TRUNCATE_VALUE_OPTS = {"-s", "--size", "-r", "--reference"}
_SHRED_VALUE_OPTS = {"-n", "--iterations", "-s", "--size", "--random-source"}
_ENV_VALUE_OPTS = {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}


def _opaque_mutation_reason(what):
    return (
        f"IDC Path Gate denied this mutation because {what}, so the exact repository targets "
        "cannot be proven before execution. Use a literal command that names the target files or a "
        "sanctioned IDC command to open the correct write boundary first."
    )


def _no_verify_reason(subcommand):
    suffix = " (or `-n`)" if subcommand == "commit" else ""
    return (
        f"IDC Path Gate denied this Bash command because `git {subcommand} --no-verify`{suffix} "
        "suppresses IDC's managed Git backstops. Remove the hook-suppression flag and let the "
        "IDC-managed hooks run."
    )


def _repo_candidate_path(raw_path, cwd, repo_root=None):
    if not isinstance(raw_path, str):
        return None
    candidate = raw_path.strip()
    if not candidate or candidate == "-" or candidate.startswith("&") or candidate.startswith("-"):
        return None
    if candidate in {"/dev/null", "/dev/stdout", "/dev/stderr"} or candidate.startswith("/dev/fd/"):
        return None
    if "$" in candidate or "`" in candidate:
        return None
    repo_abs = os.path.abspath(cwd if repo_root is None else repo_root)
    cwd_abs = os.path.abspath(cwd if cwd is not None else repo_abs)
    abs_path = os.path.abspath(candidate if os.path.isabs(candidate) else os.path.join(cwd_abs, candidate))
    rel = os.path.relpath(abs_path, repo_abs)
    if rel == "." or rel.startswith("..") or os.path.isabs(rel):
        return None
    return candidate


def _dedupe_paths(paths):
    out, seen = [], set()
    for item in paths:
        if not item or item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def _is_path_like_arg(arg):
    return bool(arg) and not arg.startswith("-") and not _ASSIGN_RE.match(arg)


def _file_operands(args, value_opts):
    operands = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            operands.extend(a for a in args[i + 1:] if _is_path_like_arg(a))
            break
        if arg in value_opts and i + 1 < len(args):
            i += 2
            continue
        if _is_path_like_arg(arg):
            operands.append(arg)
        i += 1
    return operands


def _copy_destination(args):
    for i, arg in enumerate(args):
        if arg in {"-t", "--target-directory"}:
            return [args[i + 1]] if i + 1 < len(args) else []
        if arg.startswith("--target-directory="):
            return [arg.split("=", 1)[1]]
    path_args = [arg for arg in args if _is_path_like_arg(arg)]
    return [path_args[-1]] if path_args else []


def _last_path_like_arg(args):
    for arg in reversed(args):
        if _is_path_like_arg(arg) and not arg.startswith("s/"):
            return arg
    return None


def _inline_writer_code(args):
    for i, arg in enumerate(args[:-1]):
        if arg in {"-c", "-e"}:
            return args[i + 1]
    return None


_INLINE_WRITER_MUTATION_RE = re.compile(
    r"(writeFileSync|appendFileSync|writeFile\b|appendFile\b|createWriteStream|rmSync|rmdirSync|unlinkSync|"
    r"fs\.(?:write|append|rm|unlink|rmdir)|\.write_text\s*\(|\.write_bytes\s*\(|"
    r"open\s*\([^)]*,\s*['\"](?:w|a|x)|os\.(?:remove|unlink|rmdir|truncate)|"
    r"shutil\.(?:rmtree|move|copy)|\.unlink\s*\(|\.rmtree\s*\()"
)


def _extract_apply_patch_paths(command, cwd, repo_root=None):
    if not re.search(r"(^|\s)apply_patch($|\s)", command):
        return [], False
    paths = []
    for match in re.finditer(r"(?m)^\*\*\* (?:Update|Add|Delete) File: (.+?)\s*$", command):
        candidate = _repo_candidate_path(match.group(1), cwd, repo_root)
        if candidate:
            paths.append(candidate)
    return _dedupe_paths(paths), True


def _extract_inline_writer_paths(head, args, cwd, repo_root=None):
    code = _inline_writer_code(args)
    if not isinstance(code, str) or not code:
        return []
    patterns = []
    if head in {"python", "python3"}:
        patterns = [
            re.compile(r"open\(\s*(['\"])([^'\"]+)\1\s*,\s*(['\"])[^'\"]*[wax][^'\"]*\3"),
            re.compile(r"Path\(\s*(['\"])([^'\"]+)\1\s*\)\.(?:write_text|write_bytes)\s*\("),
        ]
    elif head in {"node", "bun", "deno"}:
        patterns = [re.compile(r"(?:writeFileSync|appendFileSync|createWriteStream)\(\s*(['\"])([^'\"]+)\1")]
    elif head == "ruby":
        patterns = [re.compile(r"(?:File\.(?:write|binwrite)|File\.open)\(\s*(['\"])([^'\"]+)\1")]
    out = []
    for pattern in patterns:
        for match in pattern.finditer(code):
            candidate = _repo_candidate_path(match.group(2), cwd, repo_root)
            if candidate:
                out.append(candidate)
    return _dedupe_paths(out)


def _next_cwd(current_cwd, args):
    operands = [arg for arg in args if not arg.startswith("-") or arg == "-"]
    if not operands:
        return None
    target = operands[0]
    if len(operands) > 1 or target == "-" or re.search(r"[$`*?\[]", target):
        return None
    if target == "~" or target.startswith("~/"):
        return os.path.abspath(os.path.expanduser(target))
    if os.path.isabs(target):
        return os.path.abspath(target)
    if current_cwd is None:
        return None
    return os.path.normpath(os.path.join(current_cwd, target))


def _read_balanced_paren(command, start):
    depth = 1
    i = start
    body = []
    single = False
    dbl = False
    while i < len(command) and depth > 0:
        ch = command[i]
        if single:
            if ch == "'":
                single = False
            body.append(ch)
            i += 1
            continue
        if dbl:
            if ch == '"':
                dbl = False
            body.append(ch)
            i += 1
            continue
        if ch == "\\":
            body.append(ch)
            if i + 1 < len(command):
                body.append(command[i + 1])
            i += 2
            continue
        if ch == "'":
            single = True
            body.append(ch)
            i += 1
            continue
        if ch == '"':
            dbl = True
            body.append(ch)
            i += 1
            continue
        if ch == "(":
            depth += 1
            body.append(ch)
            i += 1
            continue
        if ch == ")":
            depth -= 1
            if depth == 0:
                i += 1
                break
            body.append(ch)
            i += 1
            continue
        body.append(ch)
        i += 1
    return "".join(body), i


def _extract_command_substitutions(command):
    bodies = []
    i = 0
    single = False
    while i < len(command):
        ch = command[i]
        if single:
            if ch == "'":
                single = False
            i += 1
            continue
        if ch == "'":
            single = True
            i += 1
            continue
        if ch == "\\":
            i += 2
            continue
        if ch == "`":
            j = i + 1
            body = []
            while j < len(command) and command[j] != "`":
                if command[j] == "\\" and j + 1 < len(command):
                    body.append(command[j + 1])
                    j += 2
                else:
                    body.append(command[j])
                    j += 1
            bodies.append("".join(body))
            i = j + 1
            continue
        if ch == "$" and command[i + 1:i + 3] == "((":
            _, end = _read_balanced_paren(command, i + 2)
            i = end + 1 if end < len(command) and command[end:end + 1] == ")" else end
            continue
        if ch in "$<>" and command[i + 1:i + 2] == "(":
            body, end = _read_balanced_paren(command, i + 2)
            bodies.append(body)
            i = end
            continue
        i += 1
    return bodies


def _git_subcommand_and_args(args):
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"}:
            i += 2
            continue
        if arg.startswith("-C") and arg != "-C":
            i += 1
            continue
        if arg.startswith("-c") and arg != "-c":
            i += 1
            continue
        if arg.startswith("--git-dir=") or arg.startswith("--work-tree=") or arg.startswith("--namespace=") or arg.startswith("--config-env="):
            i += 1
            continue
        if arg.startswith("-"):
            i += 1
            continue
        return arg, args[i + 1:]
    return None, []


def _git_no_verify_hit(args):
    subcommand, subargs = _git_subcommand_and_args(args)
    if subcommand == "commit" and ("--no-verify" in subargs or "-n" in subargs):
        return "commit"
    if subcommand == "push" and "--no-verify" in subargs:
        return "push"
    return None


def _startup_env_targets(seg):
    targets = []
    i = 0
    while i < len(seg) and _ASSIGN_RE.match(seg[i]):
        m = _STARTUP_ENV_RE.match(seg[i])
        if m and m.group(1) != "":
            targets.append(m.group(1))
        i += 1
    if i < len(seg) and os.path.basename(seg[i]) == "env":
        i += 1
        while i < len(seg):
            tok = seg[i]
            if tok == "--":
                break
            if tok in {"-S", "--split-string"} or tok.startswith("--split-string=") or (tok.startswith("-S") and not tok.startswith("--") and len(tok) > 2):
                break
            if tok in _ENV_VALUE_OPTS and i + 1 < len(seg):
                i += 2
                continue
            if tok.startswith("-"):
                i += 1
                continue
            if _ASSIGN_RE.match(tok):
                m = _STARTUP_ENV_RE.match(tok)
                if m and m.group(1) != "":
                    targets.append(m.group(1))
                i += 1
                continue
            break
    return targets


def _analyze_shell_target(target, cwd, repo_root, plugin_root, depth, seen):
    analysis = _ShellGateAnalysis()
    lexical = os.path.normpath(target if os.path.isabs(target) else os.path.join(cwd, target))
    real = os.path.realpath(lexical)
    display = target
    if _is_sensitive(os.path.basename(real)) or _is_sensitive(os.path.basename(lexical)):
        analysis.deny(_opaque_mutation_reason(f"`{display}` is a sensitive shell target the interlock refuses to open"))
        return analysis
    if plugin_root:
        scripts_dir = os.path.normpath(os.path.realpath(os.path.join(plugin_root, "scripts")))
        if real == scripts_dir or real.startswith(scripts_dir + os.sep):
            return analysis
    if real in seen:
        analysis.deny(_opaque_mutation_reason(f"`{display}` is a cyclic shell include"))
        return analysis
    if depth + 1 > MAX_SCRIPT_DEPTH:
        analysis.deny(_opaque_mutation_reason(f"`{display}` nests past depth {MAX_SCRIPT_DEPTH}"))
        return analysis
    if not os.path.isfile(real):
        analysis.deny(_opaque_mutation_reason(f"`{display}` is not a readable regular file"))
        return analysis
    try:
        if os.path.getsize(real) > MAX_SCRIPT_BYTES:
            analysis.deny(_opaque_mutation_reason(f"`{display}` is larger than {MAX_SCRIPT_BYTES} bytes"))
            return analysis
        with open(real, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read(MAX_SCRIPT_BYTES + 1)
    except OSError:
        analysis.deny(_opaque_mutation_reason(f"`{display}` is unreadable"))
        return analysis
    analysis.merge(_analyze_shell_mutations(body, cwd, repo_root, plugin_root, depth + 1, seen | {real}))
    return analysis


def _su_command_payload(seg):
    for i, tok in enumerate(seg[1:], 1):
        if tok in {"-c", "--command"}:
            return True, seg[i + 1] if i + 1 < len(seg) else None
        if tok.startswith("--command="):
            return True, tok.split("=", 1)[1]
        if tok.startswith("-c") and not tok.startswith("--") and len(tok) > 2:
            return True, tok[2:]
    return False, None


def _analyze_su_segment(seg, cwd, repo_root, plugin_root, depth, seen):
    analysis = _ShellGateAnalysis()
    has_command, payload = _su_command_payload(seg)
    if has_command:
        if not payload or _has_shell_expansion(payload):
            analysis.deny(_opaque_mutation_reason("a dynamic `su -c` payload could mutate repository paths"))
            return analysis
        if depth + 1 > MAX_SCRIPT_DEPTH:
            analysis.deny(_opaque_mutation_reason(f"a `su -c` payload nests past depth {MAX_SCRIPT_DEPTH}"))
            return analysis
        analysis.merge(_analyze_shell_mutations(payload, cwd, repo_root, plugin_root, depth + 1, seen))
        return analysis
    for i, tok in enumerate(seg[1:], 1):
        if os.path.basename(tok) in INTERPRETERS or tok in {"source", "."}:
            return _analyze_indirection_segment(seg[i:], cwd, repo_root, plugin_root, depth, seen)
    return analysis


def _analyze_indirection_segment(seg, cwd, repo_root, plugin_root, depth, seen):
    analysis = _ShellGateAnalysis()
    seg = _peel_to_inspect_head(seg)
    if not seg:
        return analysis
    for target in _startup_env_targets(seg):
        if "$" in target or "`" in target:
            analysis.deny(_opaque_mutation_reason("a startup-file target is dynamic"))
            return analysis
        analysis.merge(_analyze_shell_target(target, cwd, repo_root, plugin_root, depth, seen))
        if analysis.deny_reason:
            return analysis
    payload = _env_split_payload(seg)
    if payload is not None:
        if _has_shell_expansion(payload):
            analysis.deny(_opaque_mutation_reason("a dynamic `env -S` payload could mutate repository paths"))
            return analysis
        if depth + 1 > MAX_SCRIPT_DEPTH:
            analysis.deny(_opaque_mutation_reason(f"an `env -S` payload nests past depth {MAX_SCRIPT_DEPTH}"))
            return analysis
        analysis.merge(_analyze_shell_mutations(payload, cwd, repo_root, plugin_root, depth + 1, seen))
        return analysis
    seg = _strip_prefixes(seg)
    if not seg:
        return analysis
    if os.path.basename(seg[0]) == "su":
        return _analyze_su_segment(seg, cwd, repo_root, plugin_root, depth, seen)
    if seg[0] in {"source", "."} and len(seg) >= 2:
        analysis.merge(_analyze_shell_target(seg[1], cwd, repo_root, plugin_root, depth, seen))
        return analysis
    head = os.path.basename(seg[0])
    if head in INTERPRETERS:
        payload, sources, script = _interpreter_plan(seg[1:])
        if payload is not None:
            if _has_shell_expansion(payload):
                analysis.deny(_opaque_mutation_reason(f"a dynamic `{head} -c` payload could mutate repository paths"))
                return analysis
            if depth + 1 > MAX_SCRIPT_DEPTH:
                analysis.deny(_opaque_mutation_reason(f"a `{head} -c` payload nests past depth {MAX_SCRIPT_DEPTH}"))
                return analysis
            analysis.merge(_analyze_shell_mutations(payload, cwd, repo_root, plugin_root, depth + 1, seen))
            if analysis.deny_reason:
                return analysis
        for target in [*sources, *([script] if script is not None else [])]:
            analysis.merge(_analyze_shell_target(target, cwd, repo_root, plugin_root, depth, seen))
            if analysis.deny_reason:
                break
    return analysis


def _analyze_direct_segments(tokens, cwd, repo_root):
    analysis = _ShellGateAnalysis()
    current_cwd = os.path.abspath(cwd)

    def candidate(raw):
        if current_cwd is None and not (os.path.isabs(raw) or raw == "~" or raw.startswith("~/")):
            analysis.deny(_opaque_mutation_reason("a preceding `cd` made later relative paths unprovable"))
            return None
        return _repo_candidate_path(raw, current_cwd or repo_root, repo_root)

    for seg in _segments(tokens):
        if analysis.deny_reason:
            break
        for i, tok in enumerate(seg):
            if tok in {">", ">>", ">|"} and i + 1 < len(seg):
                hit = candidate(seg[i + 1])
                if hit:
                    analysis.add_paths([hit])
            elif tok.isdigit() and i + 2 < len(seg) and seg[i + 1] in {">", ">>", ">|"}:
                hit = candidate(seg[i + 2])
                if hit:
                    analysis.add_paths([hit])
        peeled = _strip_prefixes(seg)
        if not peeled:
            continue
        head = os.path.basename(peeled[0])
        args = peeled[1:]
        if head == "cd":
            current_cwd = _next_cwd(current_cwd, args)
            continue
        if head == "git":
            subcommand = _git_no_verify_hit(args)
            if subcommand:
                analysis.deny(_no_verify_reason(subcommand))
            continue
        if head in {"rm", "mkdir", "touch"}:
            for arg in args:
                if _is_path_like_arg(arg):
                    hit = candidate(arg)
                    if hit:
                        analysis.add_paths([hit])
            continue
        if head == "shred":
            for arg in _file_operands(args, _SHRED_VALUE_OPTS):
                hit = candidate(arg)
                if hit:
                    analysis.add_paths([hit])
            continue
        if head in {"mv", "ln"}:
            for arg in args:
                if _is_path_like_arg(arg):
                    hit = candidate(arg)
                    if hit:
                        analysis.add_paths([hit])
            continue
        if head in {"cp", "install"}:
            for arg in _copy_destination(args):
                hit = candidate(arg)
                if hit:
                    analysis.add_paths([hit])
            continue
        if head == "truncate":
            for arg in _file_operands(args, _TRUNCATE_VALUE_OPTS):
                hit = candidate(arg)
                if hit:
                    analysis.add_paths([hit])
            continue
        if head == "find":
            if any(arg in {"-exec", "-execdir", "-ok"} for arg in args):
                analysis.deny(_opaque_mutation_reason("`find -exec` can mutate repository paths without a statically provable target set"))
            elif "-delete" in args:
                analysis.deny(_opaque_mutation_reason("`find -delete` can mutate repository paths without a statically provable target set"))
            continue
        if head == "dd":
            of_arg = next((arg for arg in args if arg.startswith("of=")), None)
            if of_arg:
                hit = candidate(of_arg[3:])
                if hit:
                    analysis.add_paths([hit])
            continue
        if head == "tee":
            for arg in args:
                if _is_path_like_arg(arg):
                    hit = candidate(arg)
                    if hit:
                        analysis.add_paths([hit])
            continue
        if head == "sed" and any(arg == "-i" or arg.startswith("-i") for arg in args):
            hit = _last_path_like_arg(args)
            if hit:
                scoped = candidate(hit)
                if scoped:
                    analysis.add_paths([scoped])
            else:
                analysis.deny(_opaque_mutation_reason("`sed -i` does not name a literal repository target"))
            continue
        if head == "perl" and any(re.match(r"^-[A-Za-z]*p[A-Za-z]*i|^-[A-Za-z]*i[A-Za-z]*p", arg) for arg in args):
            hit = _last_path_like_arg(args)
            if hit:
                scoped = candidate(hit)
                if scoped:
                    analysis.add_paths([scoped])
            else:
                analysis.deny(_opaque_mutation_reason("`perl -pi` does not name a literal repository target"))
            continue
        if head in {"python", "python3", "node", "bun", "deno", "ruby"}:
            paths = _extract_inline_writer_paths(head, args, current_cwd or repo_root, repo_root)
            if paths:
                analysis.add_paths(paths)
            else:
                code = _inline_writer_code(args)
                if isinstance(code, str) and _INLINE_WRITER_MUTATION_RE.search(code):
                    analysis.deny(_opaque_mutation_reason(f"a `{head}` one-liner mutates files without naming a literal repository path"))
            continue
    return analysis


def _analyze_shell_mutations(command, cwd, repo_root, plugin_root, depth=0, seen=None):
    analysis = _ShellGateAnalysis()
    if seen is None:
        seen = frozenset()
    if not command or not command.strip():
        return analysis
    cleaned = _join_line_continuations(_strip_shell_comments(command))
    patch_paths, saw_apply_patch = _extract_apply_patch_paths(cleaned, cwd, repo_root)
    if saw_apply_patch:
        if patch_paths:
            analysis.add_paths(patch_paths)
        else:
            analysis.deny(_opaque_mutation_reason("the apply_patch payload did not name any repository files"))
            return analysis
    try:
        tokens = _lex(cleaned)
    except ValueError:
        if _mentions_interpreter_form(cleaned):
            analysis.deny(_opaque_mutation_reason("an unparseable shell indirection cannot be statically vetted"))
        return analysis
    for i, tok in enumerate(tokens):
        if tok in {">", ">>", ">|"} and i + 1 < len(tokens):
            hit = _repo_candidate_path(tokens[i + 1], cwd, repo_root)
            if hit:
                analysis.add_paths([hit])
        elif tok.isdigit() and i + 2 < len(tokens) and tokens[i + 1] in {">", ">>", ">|"}:
            hit = _repo_candidate_path(tokens[i + 2], cwd, repo_root)
            if hit:
                analysis.add_paths([hit])
    analysis.merge(_analyze_direct_segments(tokens, cwd, repo_root))
    if analysis.deny_reason:
        return analysis
    bodies = _extract_command_substitutions(cleaned)
    if depth + 1 > MAX_SCRIPT_DEPTH and bodies:
        analysis.deny(_opaque_mutation_reason(f"a shell substitution nests past depth {MAX_SCRIPT_DEPTH}"))
        return analysis
    for body in bodies:
        analysis.merge(_analyze_shell_mutations(body, cwd, repo_root, plugin_root, depth + 1, seen))
        if analysis.deny_reason:
            return analysis
    for target in _stdin_script_targets(tokens):
        analysis.merge(_analyze_shell_target(target, cwd, repo_root, plugin_root, depth, seen))
        if analysis.deny_reason:
            return analysis
    for seg in _segments(tokens):
        analysis.merge(_analyze_indirection_segment(seg, cwd, repo_root, plugin_root, depth, seen))
        if analysis.deny_reason:
            return analysis
    return analysis


def _shell_path_gate_request(command, cwd, plugin_root):
    repo_root = os.path.abspath(cwd)
    analysis = _analyze_shell_mutations(command, repo_root, repo_root, plugin_root)
    if analysis.deny_reason:
        return {"action": "bash", "raw_reason": analysis.deny_reason}
    return {"action": "write", "paths": analysis.paths} if analysis.paths else None


def _apply_path_gate_decision(decision, fallback_reason):
    observe = decision.get("observe")
    if isinstance(observe, str) and observe:
        H.pre_tool_observe(observe)
    if decision.get("allowed"):
        H.pre_tool_allow()
    H.pre_tool_deny(str(decision.get("reason") or fallback_reason))


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        H.pre_tool_allow()

    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}

    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command.strip():
            H.pre_tool_allow()
        # Classification is posture-independent (classify() ignores its `active` flag by contract), so
        # the adapter translates the Bash payload into one raw-mutation request and the shared Path Gate
        # decides the deny.
        finding = classify(command, cwd, plugin_root, False)
        if finding:
            decision = PG.evaluate_request(cwd, plugin_root, {"action": "bash", "raw_reason": render_reason(finding, plugin_root)})
            _apply_path_gate_decision(decision, "IDC interlock denied the raw governed mutation")
        request = _shell_path_gate_request(command, cwd, plugin_root)
        if request is None:
            H.pre_tool_allow()
        if request.get("action") != "bash" and subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            decision = PG.evaluate_request(cwd, plugin_root, {
                "action": "bash",
                "raw_reason": _opaque_mutation_reason("the governed repo is not inside a Git worktree, so IDC cannot verify a live authorization"),
            })
            _apply_path_gate_decision(decision, "IDC Path Gate could not verify the repository mutation")
        decision = PG.evaluate_request(cwd, plugin_root, request)
        _apply_path_gate_decision(decision, "IDC Path Gate denied the repository mutation")

    if tool in {"Write", "Edit"}:
        path_value = tool_input.get("file_path") or tool_input.get("path")
        if not isinstance(path_value, str) or not path_value.strip():
            H.pre_tool_allow()
        action = "write" if tool == "Write" else "edit"
        if subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            decision = PG.evaluate_request(cwd, plugin_root, {
                "action": action,
                "raw_reason": _opaque_mutation_reason("the governed repo is not inside a Git worktree, so IDC cannot verify a live authorization"),
            })
            _apply_path_gate_decision(decision, "IDC Path Gate could not verify the repository mutation")
        decision = PG.evaluate_request(cwd, plugin_root, {"action": action, "paths": [path_value]})
        _apply_path_gate_decision(decision, "IDC Path Gate denied the repository mutation")

    H.pre_tool_allow()


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
