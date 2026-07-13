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
removed (the active-command deny is the shipped enforcement). There are no command-name exceptions:
Init and Uninstall lifecycle writes run through validating tracker-adapter helpers, while the same raw
GitHub operations remain denied under every active IDC command.

CLASSIFIER: defense-in-depth through one quote-aware EXECUTION-SURFACE model, NOT a complete shell
parser. Each outer command position carries its dequoted argv, quoted-vs-splitting expansion roles,
local/compound-group redirections, pipe provenance, and raw spelling only where GraphQL quote style is
meaningful. Real command/process substitutions, static `eval`/`-c` payloads, interpreter files, and
shell-executed stdin (including explicit `bash|sh|zsh -s`) recurse through that same model; opaque
executable surfaces fail closed. Heredoc bodies stay data for `cat` but become code for a bare shell,
while a `gh issue create` phrase in an ordinary argument is never mistaken for executable code.
Protected API endpoints are classified from their dequoted token, with every write indicator still
scanned order-robustly. A protected `gh api` path is allowed only when provably a pure read.

INDIRECTION-AWARE (bounded interpreter inspection). Beyond the direct command-string classifier,
inspect_command resolves:
  * quoted `bash -c '…'` / `sh -c '…'` / `zsh -c '…'` payloads (recursively);
  * static `eval '…'` payloads and static here-string/heredoc shell stdin (recursively);
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
wrapper around an interpreter, a dynamic interpreter/`-c`/`env -S` target, or an unresolved unquoted
expansion in executable-head position that can split into several command words. This is
defense-in-depth, not a complete shell parser; a `$VAR` in an ordinary data argument is deliberately
never treated as a command.

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


@dataclasses.dataclass(frozen=True)
class _Finding:
    """Private classifier record. Policy tags stay private; the public Finding contract is exact."""
    subject: str
    remediation: str
    source: str
    kind: str = ""


@dataclasses.dataclass(frozen=True)
class _Heredoc:
    """One heredoc body removed from the outer shell program before command segmentation."""
    marker: str
    body: str
    quoted: bool


@dataclasses.dataclass(frozen=True)
class _ShellSubstitution:
    """One independently executed substitution plus its outer-shell word-splitting role."""
    marker: str
    command: str
    quoted: bool


@dataclasses.dataclass(frozen=True)
class _ExecutionSurface:
    """One shell command position, with every shell-owned execution role kept together."""
    raw: str
    tokens: tuple
    operators: tuple
    io_numbers: tuple
    piped_stdin: bool = False
    expansion_roles: tuple = ()
    inherited_redirections: tuple = ()


@dataclasses.dataclass
class _CompoundGroup:
    """A parenthesized/brace command group and the stdin syntax owned by that group."""
    kind: str
    piped_stdin: bool
    redirections: list = dataclasses.field(default_factory=list)


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


# Shared compatibility helper for the fail-open PostToolUse issue-create observer. The interlock's
# executable classifier deliberately does NOT use this broad text matcher: it identifies the structural
# command head below. `idc_post_issue_create.py` uses `_has` only to decide whether to emit a reminder
# after a tool result already confirms that an issue was created.
_WS = r"\s+"


def _has(command, *word_seqs):
    """True iff ``command`` contains every whitespace-flexible word sequence requested by the caller."""
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
    """The POSITIONAL word sequence of a `gh …` command SEGMENT — options at ANY level stripped (incl.
    their consumed values and the self-contained `--opt=val`/`-Rval`/`-XDELETE` forms) — or None if the
    segment has no `gh` command head. `gh issue -R o/r create` → ['issue', 'create']; the subcommand
    path can no longer be split by a flag placed between levels.

    After the shared prefix-strip (`env`/`command`/`exec`/assignments/control words plus the supported
    execution wrappers), the FIRST remaining token must itself be `gh`. A later bare `gh` is an argument,
    not the executable head (`printf '%s' gh issue create` must stay inert). Command substitutions are
    extracted and inspected separately before this function is called."""
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
        return _mk(f"a raw `gh pr {verb}`", _FINISH, "pr-merge" if verb == "merge" else f"pr-{verb}")
    # Keep distinct private kinds for precise diagnostics; policy denies every protected combo.
    kind = {"delete": "project-delete", "item-delete": "project-item-delete",
            "field-create": "project-field-create", "link": "project-link"}.get(verb, "project-mutation")
    return _mk("a raw `gh project` board mutation", _ENGINE, kind)


def _api_protected_path_kind(api_words):
    """Which protected endpoint the shell-normalized `gh api` argv names.

    Quote removal and backslash processing are shell syntax, so the executable endpoint is the
    DEQUOTED token (`graph"ql"` and `graph\\ql` both execute as `graphql`). Inspect normalized tokens,
    never their raw spelling. The scan remains deliberately blunt across the API positionals: an
    unknown gh flag such as the historical `-p nebula` probe must not hide a later protected REST
    endpoint merely because `_gh_positionals` cannot know that third-party flag's arity.
    """
    for word in api_words:
        if word == "graphql":
            return "graphql"
        if "dependencies/blocked_by" in word:
            return "dep"
        if re.search(r"repos/[^/\s]+/[^/\s]+/issues(?:/|[?]|$)", word):
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


def _gh_api_finding(seg_str, api_words=None):
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
    no write indicator. `api_words` is the shell-normalized positional tail after `api`; its first
    word is the endpoint when gh's option grammar is known, while the full tail retains the blunt
    fallback for unknown flag layouts."""
    api_words = list(api_words or [])
    endpoint = api_words[0] if api_words else None
    dyn_ep = _is_dynamic_token(endpoint) if endpoint is not None else _raw_dynamic_api_endpoint(seg_str)
    if dyn_ep and _api_write_indicator(seg_str):
        return _dynamic("a `gh api` with a shell-expansion endpoint and a write indicator")
    kind = _api_protected_path_kind(api_words)
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


def _classify_one_segment(seg_str, tokens=None, expansion_roles=None):
    """A Finding for a protected gh operation in ONE raw shell segment (already separator-free), or
    None. Token-classify the segment (gh global flags incl. `--hostname` stripped by _gh_positionals);
    a `gh api` segment goes through the blunt path-and-write-indicator rule. Only the actual executable
    head is classified: later arguments and quoted documentation text are data. Dynamic `gh`
    subcommands/endpoints and interpreter payloads retain their existing fail-closed paths."""
    if tokens is None:
        try:
            tokens = _lex(seg_str)
        except ValueError:
            return None                        # a syntactically invalid segment does not execute
    pos = _gh_positionals(tokens)
    if pos is not None and pos and pos[0] == "api":
        # round-9 Fix A: pass the token-parsed endpoint positional so a shell-expansion endpoint
        # (`gh api "$EP" …`) is judged order-robustly (flags at any level already stripped by pos).
        return _gh_api_finding(seg_str, api_words=pos[1:])
    if pos is not None:
        return _combo_subject(pos)

    # A quoted computed executable token is one argv[0]: fail closed when its following normalized argv
    # is a protected gh shape, while a quoted computed read stays allowed. An unresolved UNQUOTED head
    # is handled separately below because field splitting may supply the entire command. A dynamic word
    # in an ordinary argument remains data (`echo "$G" issue create`).
    head = _strip_prefixes(tokens)
    if not head:
        return None
    head_i = len(tokens) - len(head)
    role = expansion_roles[head_i] if expansion_roles and head_i < len(expansion_roles) else None
    dynamic_head = role in ("quoted", "split") if role is not None else _is_dynamic_token(head[0])
    if not dynamic_head:
        return None
    # An unquoted parameter/opaque command expansion in command position is not one computed argv[0].
    # Shell field splitting may turn it into the ENTIRE command (`$CMD` -> `gh issue create`). Even an
    # apparently simple substitution can call a redefined shell function, so every split-capable head
    # fails closed rather than guessing at runtime stdout.
    if role == "split":
        return _dynamic("an unquoted computed executable that can expand into multiple command words")
    computed_pos = _gh_positionals(["gh", *head[1:]])
    if computed_pos and computed_pos[0] == "api":
        protected = _gh_api_finding(seg_str, api_words=computed_pos[1:])
    else:
        protected = _combo_subject(computed_pos)
    if protected is not None:
        return _dynamic("a computed executable token with a protected `gh` operation shape")
    return None


# ── shell execution surfaces: substitutions + top-level segments ─────────────────────────────────
# A fixed token used only in the parser's private masked copy. Keeping expansions as one inert word lets
# shlex see the outer command exactly as the shell does after parsing: an assignment value stays attached
# to its assignment, while an expansion used as a gh subcommand/endpoint or interpreter payload remains
# visibly dynamic to those existing fail-closed checks.
_EXPANSION_MASK = "__IDC_SHELL_EXPANSION__"
_SUBSTITUTION_MARKER_PREFIX = "__IDC_SUBSTITUTION_"
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


def _backtick_end(command, start):
    """Index of the unescaped closing backtick for ``command[start]``, else None."""
    i = start + 1
    while i < len(command):
        if command[i] == "\\" and i + 1 < len(command):
            i += 2
            continue
        if command[i] == "`":
            return i
        i += 1
    return None


def _paren_end(command, opening):
    """Matching close for a shell parenthesis at ``opening``, respecting quotes and nested regions.

    Nested command/process/arithmetic substitutions are skipped recursively with a fresh quote context,
    which matters for valid forms such as ``$(printf '%s' "$(inner)")``. Returns None when incomplete.
    """
    i = opening + 1
    quote = None
    while i < len(command):
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < len(command):
                i += 2
                continue
            if ch == '"':
                quote = None
                i += 1
                continue
            if ch == "`":
                end = _backtick_end(command, i)
                if end is None:
                    return None
                i = end + 1
                continue
            if ch == "$" and i + 1 < len(command) and command[i + 1] == "(":
                end = _paren_end(command, i + 1)
                if end is None:
                    return None
                i = end + 1
                continue
            i += 1
            continue

        if ch == "\\" and i + 1 < len(command):
            i += 2
            continue
        if ch == "'":
            quote = "'"
            i += 1
            continue
        if ch == '"':
            quote = '"'
            i += 1
            continue
        if ch == "`":
            end = _backtick_end(command, i)
            if end is None:
                return None
            i = end + 1
            continue
        if ch in "$<>" and i + 1 < len(command) and command[i + 1] == "(":
            end = _paren_end(command, i + 1)
            if end is None:
                return None
            i = end + 1
            continue
        if ch == "(":
            end = _paren_end(command, i)
            if end is None:
                return None
            i = end + 1
            continue
        if ch == ")":
            return i
        i += 1
    return None


def _separate_shell_substitutions(command, counter=None):
    """Return ``(masked_outer, executed_substitutions, errors)`` for one shell command string.

    Real ``$(...)``/backtick command substitutions and unquoted ``<(...)``/``>(...)`` process
    substitutions execute commands, so their bodies are returned for independent recursive inspection.
    Arithmetic ``$((...))`` is data, but any command substitutions nested inside it are still extracted.
    Single-quoted lookalikes are literal text. Every consumed expansion gets a unique marker carrying
    whether the OUTER shell quotes it. The execution-surface model therefore keeps the fact that an
    unquoted result can field-split instead of pretending every expansion is one inert word.
    """
    if counter is None:
        counter = [0]
    out, inner, errors = [], [], []
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            out.append(ch)
            if ch == "'":
                quote = None
            i += 1
            continue

        if ch == "\\" and i + 1 < n:
            out.extend((ch, command[i + 1]))
            i += 2
            continue
        if ch == "'" and quote is None:
            quote = "'"
            out.append(ch)
            i += 1
            continue
        if ch == '"':
            quote = None if quote == '"' else '"'
            out.append(ch)
            i += 1
            continue

        # `((...))` is an arithmetic COMMAND, not a command group and not a heredoc-bearing argv.
        # Harvest any real substitutions inside it, then keep one inert token in the outer surface so
        # arithmetic `<<` shifts cannot be mistaken for stdin redirections.
        if quote is None and ch == "(" and i + 1 < n and command[i + 1] == "(":
            end = _paren_end(command, i)
            if end is None:
                errors.append("an unterminated arithmetic command")
                out.append(_EXPANSION_MASK)
                break
            _masked, nested, nested_errors = _separate_shell_substitutions(
                command[i + 2:end - 1], counter)
            inner.extend(nested)
            errors.extend(nested_errors)
            out.append(_EXPANSION_MASK)
            i = end + 1
            continue

        substitution = ch == "$" and i + 1 < n and command[i + 1] == "("
        process_substitution = quote is None and ch in "<>" and i + 1 < n and command[i + 1] == "("
        if substitution or process_substitution:
            end = _paren_end(command, i + 1)
            if end is None:
                errors.append("an unterminated shell substitution")
                out.append(_EXPANSION_MASK)
                break
            # `$((...))` is arithmetic, not an executed command. Recursively harvest only real command
            # substitutions inside the arithmetic expression, then mask the expression in the outer copy.
            if substitution and i + 2 < n and command[i + 2] == "(":
                _masked, nested, nested_errors = _separate_shell_substitutions(
                    command[i + 2:end], counter)
                inner.extend(nested)
                errors.extend(nested_errors)
            else:
                body = command[i + 2:end]
                marker = f"{_SUBSTITUTION_MARKER_PREFIX}{counter[0]}__"
                counter[0] += 1
                inner.append(_ShellSubstitution(
                    marker, body, quote == '"' or process_substitution))
                out.append(marker)
                i = end + 1
                continue
            out.append(_EXPANSION_MASK)
            i = end + 1
            continue

        if ch == "`":
            end = _backtick_end(command, i)
            if end is None:
                errors.append("an unterminated backtick command substitution")
                out.append(_EXPANSION_MASK)
                break
            body = command[i + 1:end]
            marker = f"{_SUBSTITUTION_MARKER_PREFIX}{counter[0]}__"
            counter[0] += 1
            inner.append(_ShellSubstitution(marker, body, quote == '"'))
            out.append(marker)
            i = end + 1
            continue

        out.append(ch)
        i += 1
    return "".join(out), inner, errors


_HEREDOC_MARKER_PREFIX = "__IDC_HEREDOC_BODY_"


def _heredoc_delimiter(command, start):
    """Parse one heredoc delimiter word at ``start`` after ``<<`` / ``<<-``.

    Returns ``(end, dequoted_delimiter, was_quoted, error)``. Shell quote removal determines the real
    delimiter, while ``was_quoted`` records whether the parent shell expands the body.
    """
    i, n = start, len(command)
    while i < n and command[i] in " \t":
        i += 1
    word_start = i
    quote = None
    was_quoted = False
    while i < n:
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                was_quoted = True
                i += 2
                continue
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in " \t\r\n;|&()<>":
            break
        if ch in "'\"":
            quote = ch
            was_quoted = True
            i += 1
            continue
        if ch == "\\":
            was_quoted = True
            i += 2 if i + 1 < n else 1
            continue
        i += 1
    raw_word = command[word_start:i]
    if quote is not None:
        return i, None, was_quoted, "an unterminated heredoc delimiter quote"
    if not raw_word:
        return i, None, was_quoted, "a heredoc without a delimiter"
    try:
        words = shlex.split(raw_word, posix=True)
    except ValueError:
        return i, None, was_quoted, "an unparseable heredoc delimiter"
    if len(words) != 1:
        return i, None, was_quoted, "an unparseable heredoc delimiter"
    return i, words[0], was_quoted, None


def _extract_heredocs(command):
    """Remove heredoc bodies from executable shell text and replace each delimiter with one marker.

    A heredoc body is stdin DATA until its consumer is known. Keeping it out of normal command
    segmentation prevents `cat <<'EOF'` documentation from being classified as executable, while the
    marker lets the owning surface later decide whether a bare shell consumes that body as a script.
    Quoted, unquoted, and tab-stripping (`<<-`) delimiters share this one structural path.
    """
    out, docs, errors, pending = [], [], [], []
    quote = None
    at_boundary = True
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            out.append(ch)
            if ch == "'":
                quote = None
            i += 1
            at_boundary = False
            continue
        if quote == '"':
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(command[i + 1])
                i += 2
                continue
            if ch == '"':
                quote = None
            i += 1
            at_boundary = False
            continue
        if ch == "#" and at_boundary:
            end = i
            while end < n and command[end] not in "\r\n":
                end += 1
            out.append(command[i:end])
            i = end
            continue
        if ch == "\\" and i + 1 < n:
            out.extend((ch, command[i + 1]))
            i += 2
            at_boundary = False
            continue
        if ch == "'":
            quote = "'"
            out.append(ch)
            i += 1
            at_boundary = False
            continue
        if ch == '"':
            quote = '"'
            out.append(ch)
            i += 1
            at_boundary = False
            continue
        # Arithmetic shifts are not heredocs. Copy the complete arithmetic command/expression so a
        # `1 << 2` inside `((...))` cannot create a synthetic stdin surface.
        if ch == "(" and i + 1 < n and command[i + 1] == "(":
            end = _paren_end(command, i)
            if end is not None:
                out.append(command[i:end + 1])
                i = end + 1
                at_boundary = False
                continue
        if ch == "<" and command[i:i + 3] == "<<<":
            out.append("<<<")
            i += 3
            at_boundary = False
            continue
        if ch == "<" and i + 1 < n and command[i + 1] == "<" \
                and not (i + 2 < n and command[i + 2] == "<"):
            strip_tabs = i + 2 < n and command[i + 2] == "-"
            after_op = i + (3 if strip_tabs else 2)
            end, delimiter, was_quoted, error = _heredoc_delimiter(command, after_op)
            if error:
                errors.append(error)
                out.append(command[i:end])
                i = end
                continue
            marker = f"{_HEREDOC_MARKER_PREFIX}{len(docs) + len(pending)}__"
            out.extend(("<< ", marker))
            pending.append((marker, delimiter, was_quoted, strip_tabs))
            i = end
            at_boundary = False
            continue
        if ch in "\r\n" and quote is None:
            if ch == "\r" and i + 1 < n and command[i + 1] == "\n":
                i += 2
            else:
                i += 1
            out.append("\n")
            at_boundary = True
            if not pending:
                continue
            for marker, delimiter, was_quoted, strip_tabs in pending:
                body_parts = []
                found = False
                while i < n:
                    line_end = i
                    while line_end < n and command[line_end] not in "\r\n":
                        line_end += 1
                    line = command[i:line_end]
                    compare = line.lstrip("\t") if strip_tabs else line
                    if compare == delimiter:
                        if line_end < n and command[line_end] == "\r" \
                                and line_end + 1 < n and command[line_end + 1] == "\n":
                            i = line_end + 2
                        else:
                            i = line_end + 1 if line_end < n else line_end
                        found = True
                        break
                    body_parts.append(line.lstrip("\t") if strip_tabs else line)
                    if line_end < n:
                        body_parts.append("\n")
                        if command[line_end] == "\r" and line_end + 1 < n \
                                and command[line_end + 1] == "\n":
                            i = line_end + 2
                        else:
                            i = line_end + 1
                    else:
                        i = line_end
                docs.append(_Heredoc(marker, "".join(body_parts), was_quoted))
                if not found:
                    errors.append(f"an unterminated heredoc `{delimiter}`")
                    break
            pending = []
            continue
        out.append(ch)
        at_boundary = ch in _WORD_BOUNDARY_CHARS
        i += 1
    if pending:
        errors.append("a heredoc whose body never started")
    return "".join(out), docs, errors


class _ExecutionSurfaceModel:
    """The one parser boundary for executable argv, expansions, groups, pipes, and redirects.

    The security invariant is ownership: syntax that changes HOW a command executes must live on the
    same surface as that command. In particular, a group-level pipe or trailing stdin redirect belongs
    to every command inside the parenthesized/brace group, and an unquoted expansion retains its
    split-capable role until it is either proven literal or denied. No later classifier reconstructs
    either fact from a flattened word list.
    """

    def __init__(self, command, heredocs=(), substitutions=()):
        self.heredocs = tuple(heredocs)
        self.substitutions = tuple(substitutions)
        self.groups = []
        self.errors = []
        drafts = self._split(command)
        self.surfaces = []
        for raw, piped_stdin, group_ids in drafts:
            try:
                tokens, operators, io_numbers, expansion_roles = _lex_surface(
                    raw, self.substitutions)
            except ValueError:
                if _mentions_interpreter_form(raw):
                    self.errors.append("an opaque shell command the interlock could not parse")
                continue
            if not tokens:
                continue
            inherited = []
            for group_id in group_ids:
                for redirect in self.groups[group_id].redirections:
                    try:
                        r_tokens, r_operators, r_io_numbers, r_roles = _lex_surface(
                            redirect, self.substitutions)
                    except ValueError:
                        self.errors.append("an opaque compound-command redirection")
                        continue
                    inherited.append(_ExecutionSurface(
                        redirect, r_tokens, r_operators, r_io_numbers, False, r_roles, ()))
            self.surfaces.append(_ExecutionSurface(
                raw, tokens, operators, io_numbers, piped_stdin,
                expansion_roles, tuple(inherited)))

    def _redirect_only(self, raw):
        """Whether ``raw`` is solely redirects belonging to the just-closed compound group."""
        try:
            tokens, operators, io_numbers, _roles = _lex_surface(raw, self.substitutions)
        except ValueError:
            return False
        i, saw_redirect = 0, False
        while i < len(tokens):
            if io_numbers[i] is not None and i + 1 < len(tokens) and operators[i + 1]:
                i += 1
            if i >= len(tokens) or not operators[i] or i + 1 >= len(tokens):
                return False
            saw_redirect = True
            i += 2
        return saw_redirect

    @staticmethod
    def _brace_boundary(command, i):
        """A brace is group syntax only as a standalone shell word, never inside ordinary data."""
        before = command[i - 1] if i else ""
        after = command[i + 1] if i + 1 < len(command) else ""
        left = not before or before.isspace() or before in ";|&()"
        right = not after or after.isspace() or after in ";|&()<>"
        return left and right

    def _split(self, command):
        """Build raw command drafts while retaining compound-command ownership."""
        parts, buf, stack = [], [], []
        quote = None
        piped_stdin = False
        pending_closed = None
        i, n = 0, len(command)

        def inherited_pipe():
            return any(self.groups[group_id].piped_stdin for group_id in stack)

        def flush():
            nonlocal buf, pending_closed
            raw = "".join(buf)
            buf = []
            had_surface = pending_closed is not None
            if not raw.strip():
                return had_surface
            if pending_closed is not None and self._redirect_only(raw):
                self.groups[pending_closed].redirections.append(raw)
                pending_closed = None
                return True
            pending_closed = None
            group_ids = tuple(stack)
            parts.append((raw, piped_stdin, group_ids))
            return True

        def open_group(kind):
            nonlocal pending_closed, piped_stdin
            flush()
            pending_closed = None
            group_id = len(self.groups)
            self.groups.append(_CompoundGroup(kind, piped_stdin))
            stack.append(group_id)
            piped_stdin = inherited_pipe()

        def close_group(kind):
            nonlocal pending_closed, piped_stdin
            flush()
            if stack and self.groups[stack[-1]].kind == kind:
                pending_closed = stack.pop()
            else:
                pending_closed = None
            piped_stdin = inherited_pipe()

        while i < n:
            ch = command[i]
            if quote == "'":
                buf.append(ch)
                if ch == "'":
                    quote = None
                i += 1
                continue
            if quote == '"':
                buf.append(ch)
                if ch == "\\" and i + 1 < n:
                    buf.append(command[i + 1])
                    i += 2
                    continue
                if ch == '"':
                    quote = None
                i += 1
                continue
            if ch == "\\" and i + 1 < n:
                buf.extend((ch, command[i + 1]))
                i += 2
                continue
            if ch in "'\"":
                quote = ch
                buf.append(ch)
                i += 1
                continue
            if ch == "&" and i + 1 < n and command[i + 1] == ">":
                buf.append(ch)
                i += 1
                continue

            # Command substitutions/arithmetic are already inert markers. Remaining parentheses are
            # compound groups. A brace group is recognized only at command position and as its own word.
            if ch == "(":
                open_group("(")
                i += 1
                continue
            if ch == ")":
                close_group("(")
                i += 1
                continue
            if ch == "{" and not "".join(buf).strip() and self._brace_boundary(command, i):
                open_group("{")
                i += 1
                continue
            if ch == "}" and stack and self.groups[stack[-1]].kind == "{" \
                    and not "".join(buf).strip() and self._brace_boundary(command, i):
                close_group("{")
                i += 1
                continue

            if ch not in "\r\n;|&":
                buf.append(ch)
                i += 1
                continue
            if ch == "|" and i + 1 < n and command[i + 1] in "|&":
                op = command[i:i + 2]
                i += 2
            elif ch == "&" and i + 1 < n and command[i + 1] == "&":
                op = "&&"
                i += 2
            elif ch == "\r" and i + 1 < n and command[i + 1] == "\n":
                op = "\n"
                i += 2
            else:
                op = ch
                i += 1
            had_surface = flush()
            pending_closed = None
            if op in ("|", "|&"):
                piped_stdin = True
            elif op in ("\n", "\r") and not had_surface and piped_stdin:
                pass
            else:
                piped_stdin = inherited_pipe()
        flush()
        return parts

    def redirections(self, surface):
        """Return local + inherited redirect state through the same model boundary."""
        return _surface_redirections(surface, self.heredocs)


_LITERAL_META = {"<": "\ue000", ">": "\ue001", "&": "\ue002"}
_RESTORE_LITERAL_META = {value: key for key, value in _LITERAL_META.items()}
_IO_NUMBER_OPEN = "\ue003"
_IO_NUMBER_CLOSE = "\ue004"
_LITERAL_EXPANSION_META = "\ue005"
_QUOTED_EXPANSION_META = "\ue006"
_SPLIT_EXPANSION_META = "\ue007"


def _mask_literal_redirection_chars(raw):
    """Protect quoted/escaped redirection characters while shlex identifies real operators."""
    out = []
    quote = None
    i = 0
    while i < len(raw):
        ch = raw[i]
        if quote == "'":
            if ch == "$":
                out.append(_LITERAL_EXPANSION_META)
            else:
                out.append(_LITERAL_META.get(ch, ch))
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "$":
                out.append(_QUOTED_EXPANSION_META)
            else:
                out.append(_LITERAL_META.get(ch, ch))
            if ch == "\\" and i + 1 < len(raw):
                escaped = raw[i + 1]
                if escaped == "$":
                    out.append(_LITERAL_EXPANSION_META)
                else:
                    out.append(_LITERAL_META.get(escaped, escaped))
                i += 2
                continue
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < len(raw) and raw[i + 1] in set(_LITERAL_META) | {"$"}:
            escaped = raw[i + 1]
            out.append(_LITERAL_META.get(escaped, _LITERAL_EXPANSION_META))
            i += 2
            continue
        if ch == "$":
            out.append(_SPLIT_EXPANSION_META)
            i += 1
            continue
        # Shell grammar recognizes an IO number only when an unquoted all-digit word is IMMEDIATELY
        # adjacent to `<`/`>`. Preserve that role so `bash 2>err` stays a bare shell, while
        # `bash 2 >err` keeps `2` as the positional script argument it really is.
        if ch.isdigit() and (i == 0 or raw[i - 1] in " \t\r\n;|&()"):
            end = i + 1
            while end < len(raw) and raw[end].isdigit():
                end += 1
            if end < len(raw) and raw[end] in "<>":
                out.extend((_IO_NUMBER_OPEN, raw[i:end], _IO_NUMBER_CLOSE))
                i = end
                continue
        out.append(ch)
        if ch in "'\"":
            quote = ch
        i += 1
    return "".join(out)


def _lex_surface(raw, substitutions=()):
    """Return dequoted values plus aligned redirect and expansion syntax roles.

    An unquoted expansion keeps a `split` role, distinct from a quoted one-word expansion. Shell
    functions and inherited environment can change even an apparently simple substitution command,
    so this static interlock never guesses at its stdout.
    """
    masked_tokens = _lex(_mask_literal_redirection_chars(raw))
    values, operators, io_numbers, expansion_roles = [], [], [], []
    substitutions_by_marker = {item.marker: item for item in substitutions}
    for token in masked_tokens:
        role = "none"
        for marker, item in substitutions_by_marker.items():
            if marker not in token:
                continue
            token = token.replace(marker, _EXPANSION_MASK)
            role = "quoted" if item.quoted else "split"
        if _SPLIT_EXPANSION_META in token:
            role = "split"
        elif _QUOTED_EXPANSION_META in token and role != "split":
            role = "quoted"
        has_literal_meta = any(marker in token for marker in _RESTORE_LITERAL_META)
        operators.append(not has_literal_meta and token in _REDIRECTION_TOKENS)
        io_number = None
        if token.startswith(_IO_NUMBER_OPEN) and token.endswith(_IO_NUMBER_CLOSE):
            candidate = token[len(_IO_NUMBER_OPEN):-len(_IO_NUMBER_CLOSE)]
            if candidate.isdigit():
                token, io_number = candidate, candidate
        for marker, value in _RESTORE_LITERAL_META.items():
            token = token.replace(marker, value)
        token = token.replace(_LITERAL_EXPANSION_META, "$")
        token = token.replace(_QUOTED_EXPANSION_META, "$")
        token = token.replace(_SPLIT_EXPANSION_META, "$")
        values.append(token)
        io_numbers.append(io_number)
        expansion_roles.append(role)
    return tuple(values), tuple(operators), tuple(io_numbers), tuple(expansion_roles)


# ── bounded interpreter inspection (Task 3) ───────────────────────────────────────────────────────


def _lex(command):
    """Shell-like tokens (quotes respected, operators split out). Raises ValueError on a parse
    failure (e.g. an unbalanced quote) — the caller decides whether that is opaque indirection."""
    lx = shlex.shlex(command, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    return list(lx)


def _mentions_interpreter_form(command):
    """True iff raw text names a shell-evaluation head whose unparseable payload is opaque."""
    if re.search(r"(?<![\w./-])(?:bash|sh|zsh|source|eval)(?![\w-])", command):
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
    backtick. shlex has already stripped the surrounding quotes; the private expansion marker preserves
    that signal after structural substitution extraction. The resolved command is opaque (round-8 Fix 2)."""
    return "$" in payload or "`" in payload or _EXPANSION_MASK in payload


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
    cannot statically confirm is not `graphql` / a protected REST path. The private expansion marker
    preserves the same signal after command-substitution extraction."""
    return bool(tok) and ("$" in tok or "`" in tok or _EXPANSION_MASK in tok)


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
# env/command/builtin/exec family above. Both the gh path and interpreter path require an EXACT normalized
# head token, so they share this wrapper strip and cannot drift. Each entry lists the wrapper's SHORT/long
# options that CONSUME the
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
    `-S`/`-u NAME`/`-i` options are consumed). Shared by the gh path (which then requires `gh` as the exact
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


def _is_dash_s_flag(tok):
    """True when a short option word explicitly selects stdin, without an ambiguous `c` payload."""
    return (len(tok) >= 2 and tok[0] == "-" and tok[1] != "-" and "s" in tok[1:]
            and "c" not in tok[1:] and all(ch.isalpha() for ch in tok[1:]))


def _interpreter_plan(args):
    """Single walk of a shell arg list, returning `(payload, sources, script, stdin_program)`:

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
        returned — only the first positional is the script.
      * `stdin_program` — `-s` explicitly makes stdin the program. Every later positional (including
        one after `--`) is a shell parameter, never a script target that suppresses stdin inspection.
    """
    payload, sources, script, stdin_program = None, [], None, False
    i, n = 0, len(args)
    while i < n:
        tok = args[i]
        if tok == "--":                                      # with -s, remaining words are parameters
            rest = args[i + 1:]
            if not stdin_program:
                script = rest[0] if rest else None
            break
        if _is_dash_c_flag(tok):                             # `-c`/`-xc` PAYLOAD — command string, not a file
            if i + 1 < n:
                payload = args[i + 1]
            break                                            # after -c everything is positional; stop
        if _is_dash_s_flag(tok):                              # stdin program; later positionals are argv
            stdin_program = True
            i += 1
            continue
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
        if not stdin_program:
            script = tok                                     # first non-flag positional = the script
        break
    return payload, sources, script, stdin_program


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
    # `eval ARG…` joins its dequoted argv with spaces and parses the result as a fresh shell program.
    # A fully static payload therefore recurses through the SAME execution-surface model. Any shell
    # expansion in that payload is runtime-computed code, so fail closed without echoing its contents.
    if os.path.basename(seg[0]) == "eval":
        args = seg[1:]
        if args[:1] == ["--"]:
            args = args[1:]
        if not args:
            return []
        payload = " ".join(args)
        if _has_shell_expansion(payload):
            return [_opaque_shell("a dynamic `eval` payload")]
        if depth + 1 > MAX_SCRIPT_DEPTH:
            return [_opaque_shell(f"an `eval` payload nested past depth {MAX_SCRIPT_DEPTH}")]
        return collect_findings(payload, cwd, plugin_root, depth + 1, seen)
    # `source FILE` / `. FILE` — a shell BUILTIN at the head (never wrapped by nohup/timeout/…), so it is
    # matched on the exact stripped head BEFORE the interpreter scan, so a target literally named `bash`
    # is inspected as a sourced file, not mistaken for an interpreter head.
    if seg[0] in ("source", ".") and len(seg) >= 2:
        return _inspect_target(seg[1], cwd, plugin_root, depth, seen)
    head = os.path.basename(seg[0])
    if head in INTERPRETERS:
        args = seg[1:]
        payload, sources, script, _stdin_program = _interpreter_plan(args)
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


_REDIRECTION_TOKENS = {"<", ">", ">>", "<<", "<<<", "<>", "<&", ">&", ">|", "&>", "&>>"}


def _surface_redirections(surface, heredocs):
    """Separate argv from redirects on one normalized execution surface.

    Returns ``(argv, stdin_sources, attached_heredocs, errors)``. Redirection operands are data, never
    executable argv. A stdin source is represented as ``(kind, value)`` where kind is `file`, `text`,
    `heredoc`, or `opaque`. Compound-group redirects are consumed first (outer to inner), then the
    command's own redirects, matching shell override order. Heredocs on non-stdin file descriptors are
    still returned as attached so their unquoted substitutions are inspected by the parent shell.
    """
    argv, stdin_sources, attached, errors = [], [], [], []
    docs_by_marker = {doc.marker: doc for doc in heredocs}

    def consume(candidate, keep_argv):
        tokens = list(candidate.tokens)
        operators = list(candidate.operators)
        io_numbers = list(candidate.io_numbers)
        i = 0
        while i < len(tokens):
            fd = None
            tok = tokens[i]
            if io_numbers[i] is not None and i + 1 < len(tokens) and operators[i + 1]:
                fd, tok = io_numbers[i], tokens[i + 1]
                i += 1
            if not operators[i]:
                if keep_argv:
                    argv.append(tok)
                else:
                    errors.append("an opaque compound-command redirection")
                i += 1
                continue
            if i + 1 >= len(tokens):
                errors.append(f"a `{tok}` redirection without a target")
                i += 1
                continue
            value = tokens[i + 1]
            i += 2
            if tok == "<<":
                doc = docs_by_marker.get(value)
                if doc is None:
                    errors.append("an opaque heredoc marker")
                else:
                    attached.append(doc)
                    if fd in (None, "0"):
                        stdin_sources.append(("heredoc", doc))
                continue
            if fd not in (None, "0"):
                continue
            if tok == "<":
                stdin_sources.append(("file", value))
            elif tok == "<<<":
                stdin_sources.append(("text", value))
            elif tok == "<>":
                stdin_sources.append(("file", value))
            elif tok == "<&":
                stdin_sources.append(("opaque", None))

    for inherited in surface.inherited_redirections:
        consume(inherited, False)
    consume(surface, True)
    return argv, stdin_sources, attached, errors


def _substitution_findings(text, cwd, plugin_root, depth, seen):
    """Inspect only command/process substitutions in a DATA string (such as an unquoted heredoc)."""
    out = []
    _masked, substitutions, errors = _separate_shell_substitutions(text)
    for error in errors:
        out.append(_opaque_shell(error))
    for substitution in substitutions:
        if depth + 1 > MAX_SCRIPT_DEPTH:
            out.append(_opaque_shell(f"a command substitution nested past depth {MAX_SCRIPT_DEPTH}"))
            continue
        for inner in collect_findings(substitution.command, cwd, plugin_root, depth + 1, seen):
            out.append(_Finding(f"{inner.subject}, reached through a shell substitution",
                                inner.remediation, "command-substitution", inner.kind))
    return out


def _stdin_execution_findings(surface, argv, stdin_sources, attached_docs,
                              cwd, plugin_root, depth, seen):
    """Inspect code fed through stdin when this surface is a bare bash/sh/zsh invocation."""
    out = []
    # The parent shell expands every UNQUOTED heredoc even if its consumer treats the result as data.
    # Inspect command/process substitutions only; raw `gh …` lines remain inert for `cat`/`printf`.
    for doc in attached_docs:
        if not doc.quoted:
            out.extend(_substitution_findings(doc.body, cwd, plugin_root, depth, seen))

    normalized = _strip_prefixes(argv)
    if not normalized or os.path.basename(normalized[0]) not in INTERPRETERS:
        return out
    head = os.path.basename(normalized[0])
    payload, _sources, script, _stdin_program = _interpreter_plan(normalized[1:])
    if payload is not None or script is not None:
        return out                              # -c / FILE owns execution; stdin is ordinary data

    source = stdin_sources[-1] if stdin_sources else None   # shell redirections apply left-to-right
    if source is None:
        if surface.piped_stdin:
            out.append(_opaque_shell(f"opaque piped stdin for a bare `{head}` interpreter"))
        return out
    kind, value = source
    if kind == "file":
        out.extend(_inspect_target(value, cwd, plugin_root, depth, seen))
        return out
    if kind == "opaque":
        out.append(_opaque_shell(f"opaque redirected stdin for a bare `{head}` interpreter"))
        return out
    body = value.body if kind == "heredoc" else value
    if _has_shell_expansion(body):
        out.append(_opaque_shell(f"dynamic stdin for a bare `{head}` interpreter"))
    elif depth + 1 > MAX_SCRIPT_DEPTH:
        out.append(_opaque_shell(f"stdin for `{head}` nested past depth {MAX_SCRIPT_DEPTH}"))
    else:
        out.extend(collect_findings(body, cwd, plugin_root, depth + 1, seen))
    return out


def collect_findings(command, cwd, plugin_root, depth=0, seen=None):
    """EVERY protected operation reachable through the normalized shell execution-surface model."""
    if seen is None:
        seen = frozenset()
    out = []
    if not command or not command.strip():
        return out
    # Heredoc bodies are stdin DATA until the owning consumer is known. Remove them BEFORE comment
    # stripping, substitution extraction, or segmentation, then reconnect each body to its marker.
    command, heredocs, heredoc_errors = _extract_heredocs(command)
    for error in heredoc_errors:
        out.append(_opaque_shell(error))
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
    # Shell substitutions are separate execution surfaces. Inspect each real command/process
    # substitution recursively, but mask it in the OUTER command before locating that command's head.
    # This prevents an inner read (`$(gh issue view …)`) from swallowing a following outer write, while
    # also preventing inert argument text (`printf … gh issue create`) from masquerading as a command.
    command, substitutions, substitution_errors = _separate_shell_substitutions(command)
    for error in substitution_errors:
        out.append(_opaque_shell(error))
    for substitution in substitutions:
        if depth + 1 > MAX_SCRIPT_DEPTH:
            out.append(_opaque_shell(f"a command substitution nested past depth {MAX_SCRIPT_DEPTH}"))
            continue
        for inner in collect_findings(substitution.command, cwd, plugin_root, depth + 1, seen):
            out.append(_Finding(f"{inner.subject}, reached through a shell substitution",
                                inner.remediation, "command-substitution", inner.kind))
    # Every outer executable position now comes from ONE ownership model: raw GraphQL spelling,
    # dequoted argv, quoted-vs-split expansions, local/group redirects, and pipe provenance cannot
    # drift into parallel paths.
    model = _ExecutionSurfaceModel(command, heredocs, substitutions)
    surfaces = model.surfaces
    for error in model.errors:
        out.append(_opaque_shell(error))
    for surface in surfaces:
        finding = _classify_one_segment(
            surface.raw, list(surface.tokens), list(surface.expansion_roles))
        if finding:
            out.append(finding)

    attached_markers = set()
    for surface in surfaces:
        argv, stdin_sources, attached_docs, redirect_errors = model.redirections(surface)
        attached_markers.update(doc.marker for doc in attached_docs)
        for error in redirect_errors:
            out.append(_opaque_shell(error))
        out.extend(_inspect_segment(argv, cwd, plugin_root, depth, seen))
        out.extend(_stdin_execution_findings(surface, argv, stdin_sources, attached_docs,
                                             cwd, plugin_root, depth, seen))
    # A marker hidden inside a nested/opaque construct did not reach an owning surface. Fail closed;
    # never reinterpret its body as top-level commands and never echo that body.
    if any(doc.marker not in attached_markers for doc in heredocs):
        out.append(_opaque_shell("an opaque nested heredoc execution surface"))
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

    ``active`` is deliberately part of the interface because the caller uses it to choose hard-deny
    versus warning posture. Classification itself is identical in both postures so the same raw write
    remains visible as a warning outside an active IDC command.
    """
    _ = bool(active)  # normalize truthiness without changing warn-vs-deny classification
    return inspect_command(command, cwd, plugin_root)


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

    # POSTURE: hard deny while the session owns an ACTIVE /idc:* command; warn otherwise. The deny
    # honors IDC_HOOKS_OBSERVE_ONLY=1 (the ONE debug escape) inside pre_tool_deny().
    active = bool(L.active_commands(cwd, session_id=payload.get("session_id")))
    finding = classify(command, cwd, plugin_root, active)
    if not finding:
        H.pre_tool_allow()
    reason = render_reason(finding, plugin_root)
    if active:
        H.pre_tool_deny(reason)
    H.pre_tool_warn(reason)       # non-active governed work: warn-inject, never blocks


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
