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
removed (the active-command deny is the shipped enforcement).

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


_WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_READ_METHODS = {"GET", "HEAD"}


def _api_method_class(command):
    """Classify a `gh api` HTTP method: 'write' | 'read' | 'ambiguous' | None (no explicit method flag).
    Recognizes ALL forms — `-X DELETE`, `-XDELETE`, `-X=DELETE`, `--method DELETE`, `--method=DELETE`. A
    method value that is a shell expansion / non-literal (`-X "$M"`) is 'ambiguous' (cannot be vetted)."""
    m = re.search(r"(?:--method[=\s]+|-X[=\s]*)(\S+)", command, re.I)
    if not m:
        return None
    val = m.group(1).strip("\"'").upper()
    if val in _WRITE_METHODS:
        return "write"
    if val in _READ_METHODS:
        return "read"
    return "ambiguous"


def _api_has_body(command):
    """True iff a `gh api` carries a body flag (`-f`/`-F`/`--field`/`--raw-field`/`--input`), in the
    space-separated (`-f k=v`) or combined (`-fk=v`) form — any body promotes the default GET to a POST."""
    return bool(re.search(r"(?<![\w-])(?:-[fF](?![\w-])|-[fF][A-Za-z_]|--field\b|--raw-field\b|--input\b)",
                          command))


def _is_api_write(command):
    """True iff a `gh api` call is (or cannot be proven NOT to be) a WRITE. An explicit write method or
    any body flag → write. An explicit read method (GET/HEAD) with no body → read. No method + no body →
    the default GET (a read; the doctor audit path). An AMBIGUOUS method (a shell-expansion value) →
    treated as a write so the active-command posture FAILS CLOSED — a raw write-shaped `gh api` on a
    protected path never needs to be allowed mid-command (every legit mutation goes through the engine)."""
    method = _api_method_class(command)
    if method == "write":
        return True
    if _api_has_body(command):
        return True
    if method == "read":
        return False
    if method == "ambiguous":
        return True
    return False   # no explicit method, no body → default GET


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
    """(subject, remediation) if the positional sequence's leading (noun, verb) is a protected combo."""
    if not pos or len(pos) < 2:
        return None
    noun, verb = pos[0], pos[1]
    if (noun, verb) not in _PROTECTED_COMBOS:
        return None
    if noun == "issue":
        if verb in ("close", "delete", "reopen"):
            return (f"a raw `gh issue {verb}`", _CLOSE)
        return (f"a raw `gh issue {verb}`", _ENGINE)
    if noun == "pr":
        return (f"a raw `gh pr {verb}`", _FINISH)
    return ("a raw `gh project` board mutation", _ENGINE)


def _gh_combo_findings(command):
    """The first protected gh (noun, verb) combo across the command's segments, or None. A shell parse
    failure yields None — the `_has` regex backstop in classify() still covers an unparseable body."""
    try:
        tokens = _lex(command)
    except ValueError:
        return None
    for seg in _segments(tokens):
        hit = _combo_subject(_gh_positionals(seg))
        if hit:
            return hit
    return None


def classify(command):
    """(subject, remediation) for a raw terminal/board command that bypasses the door, or None.
    The `gh api` content rules (issue-state / dependency / GraphQL writes) match the raw string so a
    JSON-body / here-string form is still caught; the gh SUBCOMMAND rules are token-NORMALIZED so gh
    global flags before the subcommand (`gh -R o/r issue create`) and combined option forms cannot
    bypass the deny. Under the active-command posture an over-match (a benign echoed line) denies in
    the safe direction (the agent re-issues through the door); outside an active command it is only a
    warning."""
    c = command
    # ── `gh api` content rules (matched on the raw string so JSON-body / here-string forms are caught) ──
    # issue-state-writing gh api — a hand issue close OR reopen (REST field forms `-f/-F state=closed`
    # / `state=open`, `state: closed`, and the JSON-body form `"state":"closed"`); case-insensitive so
    # `state=CLOSED` is caught too. Both directions are protected issue-state writes per the brief.
    if _has(c, "gh api") and re.search(r"state[\"']?\s*[=:]\s*[\"']?\s*(?:closed|open)", c, re.I):
        return ("an issue-state-writing `gh api` call", _CLOSE)
    # issue-dependency REST write — a raw dependencies/blocked_by POST/DELETE (the gate-chain door).
    # METHOD-AWARE (`_is_api_write`): a WRITE method, any body flag, OR an AMBIGUOUS (shell-expansion)
    # method fails closed; a read-only GET/HEAD on `dependencies/blocked_by` is /idc:doctor's own audit
    # read and stays ALLOWED.
    if _has(c, "gh api") and re.search(r"dependencies/blocked_by", c) and _is_api_write(c):
        return ("a raw issue-dependency REST write (`dependencies/blocked_by`)", _DEP)
    # issue-collection REST write — a POST that CREATES an issue (`repos/o/r/issues` as the terminal
    # collection, not `.../issues/N/…`). Method-aware, so listing issues (a GET) stays allowed.
    if _has(c, "gh api") and _is_api_write(c) \
            and re.search(r"repos/[^/\s'\"]+/[^/\s'\"]+/issues(?:[\s'\"?]|$)", c):
        return ("a raw issue-create REST write", _ENGINE)
    # GraphQL board/issue mutations — the write-verb-glued-to-object family (createProjectV2,
    # copyProjectV2, linkProjectV2ToRepository, updateIssue, reopenIssue, clearProjectV2ItemFieldValue,
    # archiveProjectV2Item, …). Pattern-matched, not a hand-kept name list, so a new mutation is caught.
    if _has(c, "gh api") and _GQL_WRITE.search(c):
        return ("a raw GraphQL board/issue mutation", _ENGINE)
    # ── gh SUBCOMMAND writes — TWO detectors, unioned ──
    #   (a) token-NORMALIZED (noun, verb) combos: options at ANY level are stripped, so a flag placed
    #       before OR between subcommand levels (`gh -R o/r issue create`, `gh issue -R o/r create`) and
    #       every combined option form cannot bypass the deny; the `issue new` alias resolves to create.
    #   (b) a whitespace-flexible regex backstop (`_has`) that needs no shell parse, so a match inside a
    #       complex/echoed SCRIPT BODY (heredocs, command substitutions) is caught even where the lexer
    #       chokes. Either detector firing is a deny.
    combo = _gh_combo_findings(c)
    if combo:
        return combo
    if _has(c, "gh pr merge"):
        return ("a raw `gh pr merge`", _FINISH)
    if _has(c, "gh issue create") or _has(c, "gh issue new"):
        return ("a raw `gh issue create`", _ENGINE)
    if _has(c, "gh issue close"):
        return ("a raw `gh issue close`", _CLOSE)
    if _has(c, "gh issue reopen"):
        return ("a raw `gh issue reopen`", _CLOSE)
    if _has(c, "gh project item-edit") or _has(c, "gh project item-add") \
            or _has(c, "gh project item-delete"):
        return ("a raw `gh project item-{edit,add,delete}` board mutation", _ENGINE)
    return None


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


def _inspect_target(target, cwd, plugin_root, depth, seen):
    """Resolve+vet a `bash|sh|zsh FILE` / `source FILE` / `. FILE` script target (rules 4–7)."""
    path = target if os.path.isabs(target) else os.path.join(cwd or ".", target)
    path = os.path.normpath(path)
    display = path
    base = os.path.basename(path)
    # Rule 6: sensitive — refuse WITHOUT reading (before any stat/open touches it).
    if _is_sensitive(base):
        return _opaque(display, "a sensitive file the interlock refuses to open")
    # Rule 5: files beneath the plugin's own scripts/ dir are sanctioned — do not scan their bodies.
    if plugin_root:
        scripts_dir = os.path.normpath(os.path.join(plugin_root, "scripts"))
        if path == scripts_dir or path.startswith(scripts_dir + os.sep):
            return None
    # cycle + depth guards (rule 6): a self/mutually-including script, or nesting past the bound.
    real = os.path.realpath(path)
    if real in seen:
        return _opaque(display, "a cyclic include")
    if depth + 1 > MAX_SCRIPT_DEPTH:
        return _opaque(display, "include depth exhausted")
    # follow REGULAR files only (rule 4); missing / non-regular / unreadable / too-large → opaque.
    if not os.path.isfile(path):
        return _opaque(display, "not a readable regular file")
    try:
        if os.path.getsize(path) > MAX_SCRIPT_BYTES:
            return _opaque(display, f"larger than {MAX_SCRIPT_BYTES} bytes")
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read(MAX_SCRIPT_BYTES + 1)
    except OSError:
        return _opaque(display, "unreadable")
    inner = inspect_command(body, cwd, plugin_root, depth + 1, seen | {real})
    if inner is None:
        return None
    # Keep the matched operation + its remediation; name the indirection path (rule 7: path only).
    return Finding(f"{inner.subject}, reached indirectly via `{display}`", inner.remediation,
                   "script-indirection")


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
    `--split-string=string`), return STRING — the embedded command line `env` re-parses and executes.
    It is inspected recursively (like a `bash -c` payload), so `env -S "bash fire_gate.sh"` is followed
    THROUGH to fire_gate.sh instead of consuming the string as an opaque wrapper value. Else None."""
    i = 0
    while i < len(seg) and _ASSIGN_RE.match(seg[i]):     # skip leading VAR=val
        i += 1
    if i >= len(seg) or os.path.basename(seg[i]) != "env":
        return None
    i += 1
    while i < len(seg):
        tok = seg[i]
        if tok in ("-S", "--split-string") and i + 1 < len(seg):
            return seg[i + 1]
        if tok.startswith("--split-string="):
            return tok[len("--split-string="):]
        if tok.startswith("-S") and not tok.startswith("--") and len(tok) > 2:
            return tok[2:]
        i += 1
    return None


def _inspect_segment(seg, cwd, plugin_root, depth, seen):
    """Inspect one command segment for an interpreter/source invocation (rules 3–4)."""
    # `env -S "<string>"` / `--split-string`: the embedded string IS the command — parse it recursively
    # (Fix 1), so an interpreter hidden inside the split-string is not waved through as an opaque value.
    payload = _env_split_payload(seg)
    if payload is not None:
        return inspect_command(payload, cwd, plugin_root, depth + 1, seen)
    seg = _strip_prefixes(seg)
    if not seg:
        return None
    head = os.path.basename(seg[0])
    if head in INTERPRETERS:
        args = seg[1:]
        # Rule 3: a quoted `-c PAYLOAD` is the whole command — recurse into it, no file target.
        for i, a in enumerate(args):
            if a == "-c" and i + 1 < len(args):
                return inspect_command(args[i + 1], cwd, plugin_root, depth + 1, seen)
        # Rule 4: `bash|sh|zsh FILE` — the first non-flag argument is the script target.
        target = next((a for a in args if not a.startswith("-")), None)
        if target:
            return _inspect_target(target, cwd, plugin_root, depth, seen)
        return None
    if seg[0] in ("source", ".") and len(seg) >= 2:
        return _inspect_target(seg[1], cwd, plugin_root, depth, seen)
    return None


def inspect_command(command, cwd, plugin_root, depth=0, seen=None):
    """The indirection-aware classifier: a Finding for a protected operation reachable from `command`
    (directly, via a bash -c payload, or inside a resolved interpreter/source FILE), else None."""
    if seen is None:
        seen = frozenset()
    if not command or not command.strip():
        return None
    # Rule 1: the direct protected-operation classifier on the whole command string.
    hit = classify(command)
    if hit:
        return Finding(hit[0], hit[1], "direct")
    # Rule 2: tokenize; a parse failure is opaque ONLY when the command invokes an interpreter form.
    try:
        tokens = _lex(command)
    except ValueError:
        if _mentions_interpreter_form(command):
            return Finding("an opaque shell command the interlock could not parse "
                           "[opaque-shell-indirection]", _ENGINE, "opaque-shell-indirection")
        return None
    # Rules 3–4: interpreter `-c` payloads and bash|sh|zsh|source|. FILE targets.
    for seg in _segments(tokens):
        f = _inspect_segment(seg, cwd, plugin_root, depth, seen)
        if f:
            return f
    return None


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

    finding = inspect_command(command, cwd, plugin_root)
    if not finding:
        H.pre_tool_allow()
    reason = render_reason(finding, plugin_root)
    # POSTURE: hard deny while the session owns an ACTIVE /idc:* command; warn otherwise. The deny
    # honors IDC_HOOKS_OBSERVE_ONLY=1 (the ONE debug escape) inside pre_tool_deny().
    active = bool(L.active_commands(cwd, session_id=payload.get("session_id")))
    if active:
        H.pre_tool_deny(reason)
    H.pre_tool_warn(reason)       # non-active governed work: warn-inject, never blocks


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
