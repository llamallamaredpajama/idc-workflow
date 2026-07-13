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
    "(create-ticket | create-pointer | claim | move | close | dispose | recirculate-intake | "
    "link | unblock) — never mutate the board with a raw `gh issue`/`gh project`/GraphQL call."
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


def classify(command):
    """(subject, remediation) for a raw terminal/board command that bypasses the door, or None.
    A pure command-string match (no shell parse), so an echoed/quoted occurrence also matches — under
    the active-command deny posture that over-denies a benign echoed line inside an IDC command, which
    is the safe direction (the agent re-issues through the door); outside an active command it is only
    a warning."""
    c = command
    # state-closing gh api — a hand issue close (REST field forms `-f/-F state=closed`, `state: closed`,
    # and the JSON-body form `"state":"closed"`).
    if _has(c, "gh api") and re.search(r"state[\"']?\s*[=:]\s*[\"']?\s*closed", c):
        return ("a state-closing `gh api` call", _CLOSE)
    # issue-dependency REST write — a raw dependencies/blocked_by POST/DELETE (the gate-chain door).
    if _has(c, "gh api") and re.search(r"dependencies/blocked_by", c):
        return ("a raw issue-dependency REST write (`dependencies/blocked_by`)", _DEP)
    # GraphQL board/issue mutations (field value / add / delete / issue create/close) — raw writes.
    if _has(c, "gh api") and re.search(r"updateProjectV2ItemFieldValue|addProjectV2ItemById|"
                                       r"deleteProjectV2Item|closeIssue|createIssue", c):
        return ("a raw GraphQL board/issue mutation", _ENGINE)
    if _has(c, "gh pr merge"):
        return ("a raw `gh pr merge`", _FINISH)
    if _has(c, "gh issue create"):
        return ("a raw `gh issue create`", _ENGINE)
    if _has(c, "gh issue close"):
        return ("a raw `gh issue close`", _CLOSE)
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
        if t in _SEP or (t and all(ch in "&|;()<>" for ch in t)):
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


def _inspect_segment(seg, cwd, plugin_root, depth, seen):
    """Inspect one command segment for an interpreter/source invocation (rules 3–4)."""
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


def render_reason(finding):
    """The model-visible remediation string (a deny reason, or a warn line)."""
    return (
        f"IDC interlock: {finding.subject} bypasses the single write door (the 394ec6fe "
        f"hand-rolled-finish / loose-improvisation class). Do not run it by hand — {finding.remediation}"
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
    reason = render_reason(finding)
    # POSTURE: hard deny while the session owns an ACTIVE /idc:* command; warn otherwise. The deny
    # honors IDC_HOOKS_OBSERVE_ONLY=1 (the ONE debug escape) inside pre_tool_deny().
    active = bool(L.active_commands(cwd, session_id=payload.get("session_id")))
    if active:
        H.pre_tool_deny(reason)
    H.pre_tool_warn(reason)       # non-active governed work: warn-inject, never blocks


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
