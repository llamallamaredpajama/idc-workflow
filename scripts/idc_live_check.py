#!/usr/bin/env python3
"""idc_live_check.py — the declared-live-surface EXECUTION gate (`WORKFLOW.md §4.6`).

THE FAILURE THIS EXISTS FOR. Every IDC gate verifies CODE: the review dimensions, the architectural
fences, the per-issue verification surface, the acceptance check. All of them can be green while the
DEPLOYED product is broken, because the things that break a deployment most often are not in the
reviewed diff at all — a bucket that was never created, an env var that was never set, an IAM role
granted by hand. One governed repo shipped a phase with every PR merged and every gate green while
its running app could neither ingest nor open an item
(`docs/dev/2026-07-19-completion-honesty.md`). "All PRs merged + reviewed" was read as "the app
works," and the plan's own written finish line — drive the real signed-in app — was skipped.

VERIFICATION IS EXECUTED, NOT ATTESTED. The first cut of this gate asked a HUMAN to drive the app and
hand-write an evidence note. That is the wrong shape twice over: it wakes an operator at 2am to answer
a question the pipeline can answer itself, and a typed claim is not a measurement — the same optimism
that read "merged" as "works" will read "I tested it" as "it works". So the project supplies a
`verify:` COMMAND per surface, and this gate RUNS it. The verdict comes from a real exit code; the
evidence record is a machine-generated receipt of that run, not prose.

WHAT IDC CAN HONESTLY ENFORCE. Not the deploy itself, and NOT the technology: IDC cannot know whether
your surface is driven by an authenticated HTTP call, a browser session, a mobile simulator, or a
queue probe, and hardcoding any of them would be wrong for the next repo. The project owns the script;
IDC owns the obligation, the execution, the expiry, and the honesty of the verdict.

WRITING THE VERIFY SCRIPT IS BUILD WORK. It is ordinary implementation — the same agent that builds
the surface writes the script that drives it, exactly as it writes the surface's tests. It is never an
errand handed back to the operator.

NOT-DECLARED IS A FIRST-CLASS ANSWER (the no-burden rule). A repo with no `live_verification:` block —
or one that ships the template's `surfaces: []` — gets `live: not-declared` and exit 0, always, and
NOTHING is executed. A library, a CLI, a plugin like this one has no deployed surface to drive, and
this gate must cost it exactly nothing. Opting in is the ONLY way to be gated.

A TYPED RECEIPT DOES NOT PASS, AND THAT IS ENFORCED. Every field in the committed receipt is one any
reader can recompute — the declared command comes from the config, its digest from the command, the
commit from `git rev-parse HEAD` — so no amount of checking the receipt could tell a real run from a
hand-written one, and none of it is fixable with a signature (the key would have to travel with the
repo to stay verifiable, and a key in the repo is not a secret). The proof therefore lives where git
cannot carry it: `--run` records each execution under the GIT DIRECTORY, and the audit requires the
receipt and that witness to agree. Writing the markdown by hand yields `live: gap`. The boundary,
stated plainly: this proves "this working copy really executed that command against that commit", not
"nobody tampered with the git directory" — nothing local could prove the latter. Its cost is equally
plain: a fresh clone carrying a committed receipt reports a gap naming that reason until `--run`
clears it, which is the honest answer (the receipt says the surface passed somewhere; this working
copy has not seen it happen).

A RUN IS ATTRIBUTED TO A COMMIT, so it may not start from a tree that is not that commit. The verify
command executes the WORKING TREE while the receipt records HEAD; if the surface's own files are
uncommitted the receipt would name a code state that was never exercised, so such a run is refused as
INDETERMINATE. Scoped to the surface's declared paths and tracked files only — a run always dirties
the tree by writing its own receipt.

THE TEETH: EVIDENCE EXPIRES BY ITSELF. Each declared surface names the `paths:` whose code backs it,
and each evidence record names the `commit:` that was checked out when the command ran. If ANY commit
has landed on those paths since — a code change, a Terraform change, a deploy-script change — the
evidence is STALE and the surface is a gap again. That single rule is what covers provisioning drift:
a repo that lists `infra/` among a surface's paths cannot merge a Terraform change and still claim the
app was proven working, because the proof now predates the infrastructure it describes. The recorded
`command` must also still MATCH the declared one, so weakening or swapping the check invalidates every
receipt it produced — and the freshness set includes the VERIFY SCRIPT'S OWN FILES, because editing
the probe (deleting a step, commenting out an assertion) changes what "passed" meant while leaving the
declared string identical. Evidence ages out on its own; nobody has to remember to invalidate it.

TWO MODES, ONE EXIT CONTRACT — and the reason they are split:

  * `--run`  EXECUTE. Runs each declared surface's `verify:` command in the repo root under a bounded
             timeout, regenerates that surface's evidence record from the real result (pass OR fail),
             then audits. This is what Build's wave close and Autorun's live-gap remediation call. It
             can legitimately take minutes.
  * default  AUDIT (read-only, sub-second, executes nothing). Is there a current machine-generated
             receipt showing this surface's declared command was executed and passed on the code that
             is running now? This is what `idc_autorun_drain.py --live` and the Stop fixpoint gate
             call, and it is why they stay fast: a Stop hook must never sit through a browser suite.

  The split is deliberate and load-bearing. Execution belongs where the pipeline has time to do work
  and act on a failure; the drain's job at wave close is only to ask whether that work was done.

THE DECLARATION (`WORKFLOW-config.yaml`):

    live_verification:
      surfaces:
        - name: web
          verify: bash scripts/verify-live-web.sh
          paths: [services/, web/, infra/]
          journey: sign in -> ingest text -> open the item -> chat
          evidence: docs/workflow/live-verification/web.md
          timeout: 600

`name`, `paths`, and `verify` are required; `evidence` defaults to
`docs/workflow/live-verification/<name>.md`; `timeout` defaults to 600 seconds; `journey` is prose for
whoever writes the verify script (this gate never interprets it). A surface that declares no `verify:`
is an ERROR, never a pass — an unverifiable surface must not read as verified.

THE ONE HAND-ATTESTED ESCAPE HATCH, and why it is visible. Some surfaces genuinely cannot be driven by
a script (a physical device, a third-party console, a manual compliance walkthrough). Those declare
`attested: true` INSTEAD of `verify:`, and keep the hand-written record. But an attestation is a
weaker claim than a measurement, so it never hides inside a clean verdict: the gate prints
`live: ok (attested)` and names the attested surfaces on stderr. A hand-written record on a surface
that declares a `verify:` command does NOT satisfy the gate — it is reported as never executed.

THE EVIDENCE RECORD. A committed markdown file, GENERATED by `--run` and reviewed like any other
committed artifact, carrying one machine-readable marker (the house convention, modeled on
`<!-- idc-deferral: {…} -->` / `<!-- idc-provenance: {…} -->`):

    <!-- idc-live-evidence: {"surface": "web", "mode": "executed",
         "command": "bash scripts/verify-live-web.sh", "exit_code": 0, "commit": "<40-hex sha>",
         "ran_at": "2026-07-19T04:11:07Z", "duration_s": 12.4, "observed": "<bounded excerpt>"} -->

SECRETS NEVER ENTER THE RECORD. A verify script drives a REAL deployment, so it handles real
credentials — tokens in headers, signed URLs, service-account keys. This gate therefore treats
captured output as hostile: it is REDACTED (named secrets, known credential shapes, URL userinfo, PEM
blocks, and any long opaque run) and BOUNDED before a single byte reaches disk or stderr, and the
child's environment is never captured, printed, or recorded in any form. The recorded `command` is
redacted the same way. This is a hard constraint, not a nicety: an evidence file is committed, and a
committed secret is a leak.

FAIL-CLOSED, with the house distinction between a FINDING and an INDETERMINATE (mirrors
`idc_acceptance_check.py` and `idc_gate_proof.py`). A surface whose command RAN and FAILED, or that has
no evidence / stale evidence / evidence naming a commit that is not real or not merged / evidence of a
different command, is a GAP — a finding, exit 1, and the pipeline's own work to fix. A CORRUPT marker,
a malformed declaration, a missing `verify:`, a command that cannot be executed at all (shell 126/127),
a timeout, or a repo git cannot be read in is an ERROR — exit 2. Collapsing the second into "no gap"
would let deleting a verify script manufacture a clean bill of health.

Exit contract (the sibling-helper convention — see idc_acceptance_check.py):
  exit 0  `live: not-declared`        — no live surface declared; this repo is not gated here.
  exit 0  `live: ok`                  — every declared surface was EXECUTED and passed, currently.
  exit 0  `live: ok (attested)`       — clean, but at least one surface is hand-attested, not executed.
  exit 1  `live: gap <name> …`        — those surfaces failed, or have missing/stale/foreign evidence.
  exit 2  `live: error <why>`         — the check could not be established (INDETERMINATE).

Usage: idc_live_check.py --repo <dir> [--run] [--config <WORKFLOW-config.yaml>]
"""
import argparse
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import NamedTuple

# Same-dir import: the shared credential table lives beside this script in scripts/, so this resolves
# whether the file is run directly (sys.path[0] is its own dir) or imported by a smoke test that put
# scripts/ on sys.path. See idc_credential_shapes.py for what is shared and what deliberately is not.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_credential_shapes as CS  # noqa: E402

# The evidence marker. The sentinel is matched FIRST and the payload captured up to the comment close,
# so a CORRUPT payload fails closed (exit 2) rather than slipping past a `{…}`-anchored pattern as
# "no marker at all" (the same discipline as idc_acceptance_check.DEFERRAL_MARKER).
MARKER_SENTINEL = "idc-live-evidence"
EVIDENCE_MARKER = re.compile(r"<!--\s*" + MARKER_SENTINEL + r":\s*(.*?)\s*-->", re.S)
# A real git object name. The evidence `commit` is matched against this BEFORE it is handed to git,
# because git happily resolves symbolic names: a forged marker naming `HEAD` passes rev-parse, passes
# `merge-base --is-ancestor HEAD HEAD`, and produces an empty `HEAD..HEAD` staleness log — i.e. every
# freshness rule in this file says "current" for a receipt that describes nothing. Only a full object
# name pins a receipt to one immutable code state.
_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
# Present in EVERY record, whatever produced it. `mode` is deliberately NOT here: a record with no
# `mode` is a legacy/hand-written note, which is an honest "never executed" GAP, not a corrupt file.
REQUIRED_EVIDENCE_KEYS = ("surface", "commit", "observed")

MODE_EXECUTED = "executed"
MODE_ATTESTED = "attested"
# A run that established NOTHING (timeout, unrunnable command). Not a pass and not a product finding —
# the third answer this gate has always had at the exit-code layer, now durable in the record too, so
# the read-only audit inherits it instead of reading a receipt the failed run left behind.
MODE_INDETERMINATE = "indeterminate"

CONFIG_BASENAME = "WORKFLOW-config.yaml"
BLOCK_KEY = "live_verification"
DEFAULT_EVIDENCE_DIR = "docs/workflow/live-verification"

# A verify command drives a real deployment: cold starts, sign-in, a browser. Ten minutes is a ceiling,
# not an expectation, and a surface may raise or lower it with `timeout:`. Exceeding it is INDETERMINATE
# (exit 2) — a hung probe proves nothing about the product either way.
DEFAULT_VERIFY_TIMEOUT = 600
# How much captured output survives into the record. The body keeps a readable tail; the marker keeps a
# one-line digest. Both are bounds on what is WRITTEN — a verify script that prints a novel produces a
# small record, and a leak has less surface to hide in.
MAX_BODY_CHARS = 4000
MAX_OBSERVED_CHARS = 300

# A mapping-key line inside the block: indent, key, colon, value.
_KEY_LINE = re.compile(r"^(\s*)([A-Za-z_][\w.-]*):\s*(.*)$")
# A list-item line: indent, dash, then optionally the first `key: value` on the same line.
_ITEM_LINE = re.compile(r"^(\s*)-\s*(.*)$")
# An inline-comment strip is applied ONLY to structural keys. `journey` is prose and `verify` is a
# SHELL COMMAND — both may legitimately contain `#`, and truncating a verify command at a `#` would
# silently run a different command than the one the project declared.
_STRUCTURAL_KEYS = ("name", "paths", "evidence", "attested", "timeout")

# REDACTION — applied to every captured byte that reaches disk or stderr. Ordered: the structured
# shapes first, the broad opaque-run backstop last, so a PEM block or a URL is not chewed into pieces
# by the catch-all before its own rule sees it. Over-redaction is the correct bias here; an unreadable
# excerpt costs a re-run, a leaked token costs a rotation.
#
# EVERY QUANTIFIER IS BOUNDED, and the input these run over is BOUNDED BY CAPTURE, not by the display
# cut. Both are load-bearing, not tidiness: the first draft had an unbounded `[\w.-]*` around the
# named-secret rule and redacted the whole capture, and a verify script that printed 400 KB on one line
# wedged the gate for minutes with no timeout left to save it (the command had already exited). A check
# that hangs is a check that gets removed. `tests/smoke/phase4-completion-honesty.sh` G5 is that
# regression. The 400 KB is what `_drain_bounded` now prevents: it retains at most
# `_MAX_RETAINED_BYTES` (17 KB), so the whole-capture pass these rules make is bounded at ~28 ms
# worst case. That is why `_redacted_tail` can afford to redact on BOTH sides of the display cut —
# see its docstring for why one side is never enough.
#
# THE RULES COME FROM THE SHARED TABLE, all of them — `CS.MACHINE_OUTPUT_SHAPES`, the profile for
# text a CHILD PROCESS printed. A verify command's capture is exactly that, so this file no longer
# keeps a private copy of the two rules that are right for machine output and wrong for human prose
# (the named-secret rule matches on substrings, so `TOKENIZER_MODEL=…` is a "token"; the
# `Basic`/`token` header arms match ordinary English). Keeping them here is what let the autorun
# drain build a scrub door and wire the PROSE profile through it — see that module's docstring on why
# provenance, not caller identity, selects a rule set. Every separator in the shared profile is
# BOUNDED (`\s{1,64}`, never `\s+`) and no label alternation carries a quantified GROUP, so `CS.reach`
# can measure how far one match spans; that number is what sizes `_HEAD_QUARANTINE_BYTES` below.
_LIVE_ONLY_OPAQUE_RUN_BACKSTOP = (
    # The backstop, and the ONE rule that stays local — because it is not a rule, it is a GUESS: "a
    # long opaque run is a credential we do not have a name for". A guess is affordable here, where
    # the text is a project's own probe output and nobody can characterise it in advance, and
    # unaffordable over a STRUCTURED DIAGNOSTIC, where every 40-character opaque run is the commit sha
    # or node id the message exists to carry. (It must also never run over intake text: a review
    # binding note IS a 64-character hex digest, so this rule would make every stamped review
    # permanently unvalidatable.)
    re.compile(r"\b[A-Za-z0-9_\-]{40,4096}\b"), "[REDACTED]",
)
_REDACTORS = CS.machine_output_redactors() + (_LIVE_ONLY_OPAQUE_RUN_BACKSTOP,)


def _fail(reason):
    """INDETERMINATE — print the machine-readable error line and exit 2 (never a hollow clean)."""
    print(f"live: error {reason}")
    sys.exit(2)


def redact(text):
    """Strip anything that looks like a credential. Applied before ANY capture is written or printed."""
    out = text or ""
    for pattern, repl in _REDACTORS:
        out = pattern.sub(repl, out)
    return out


def _command_sha(command):
    """A stable digest of the RAW declared command, for identity where the redacted display collides."""
    return hashlib.sha256((command or "").encode("utf-8", "replace")).hexdigest()


def neutralize(text):
    """Defuse anything in CAPTURED text that could be read back as an evidence marker.

    THE ATTACK THIS CLOSES. The evidence record puts the verify command's own output in the file, and
    the record's verdict lives in a marker comment in that same file. So a verify script can PRINT a
    marker. Without this, a failing script that echoes

        <!-- idc-live-evidence: {"surface": "web", "exit_code": 0, "commit": "HEAD", …} -->

    plants a second, forged marker in its own receipt, and the audit reads a pass out of a failed run.
    Two independent defenses, because one is not enough: the reader anchors to the LAST marker (the
    generated one is always last — see `read_evidence`), and this defuses the forged one so the file
    never contains a second parseable marker at all. Either alone would close the reported hole; both
    means a future edit to one of them cannot silently reopen it.

    Applied at the single WRITE door, to every captured value, so no caller can forget it. The escape
    is visible on purpose — a reviewer reading the receipt should SEE that the script tried this.
    """
    out = text or ""
    # Break the sentinel: the marker pattern needs `idc-live-evidence` immediately followed by `:`.
    out = out.replace(f"{MARKER_SENTINEL}:", f"{MARKER_SENTINEL}[escaped]:")
    # Break the comment delimiters too, so captured text can neither open a comment nor CLOSE the real
    # marker early (a premature `-->` inside the payload would truncate it into unparseable JSON).
    return out.replace("<!--", "<![escaped]--").replace("-->", "--[escaped]>")


def _tail(text, limit):
    """The LAST `limit` characters — a failing command's reason is at the end, not the beginning."""
    text = text or ""
    if len(text) <= limit:
        return text
    return "…[truncated]…\n" + text[-limit:]


_LEADING_WS = re.compile(r"\s")
_LEADING_WS_BYTES = re.compile(rb"\s")
_PEM_OPEN_BYTES = re.compile(CS.PEM_BLOCK_OPEN.pattern.encode("ascii"))
_PEM_CLOSE_BYTES = re.compile(CS.PEM_BLOCK_CLOSE.pattern.encode("ascii"))

# Rules whose REACH is unbounded, each mapped to the structural family that closes it in the head
# quarantine below. A rule that is neither measurable nor registered here makes this module refuse to
# load, on purpose: that is the check that keeps "the quarantine covers every rule" a property of the
# code rather than a claim in a comment.
_UNBOUNDED_RULE_FAMILY = {
    CS.PEM_PRIVATE_KEY_BLOCK[0]: "delimited-block",   # closed by its own BEGIN/END delimiters
    CS.KNOWN_CREDENTIAL_SHAPES[0]: "bare-token-run",  # closed by the whitespace boundary
}


def _head_quarantine_bytes():
    """How many leading bytes of a cut buffer are unattributable — the longest match ANY redactor
    applied here can produce, computed from the patterns themselves (`CS.reach`).

    Derived rather than typed so that adding a rule with a longer bound raises this guard by itself.
    A rule `CS.reach` cannot measure must be registered in `_UNBOUNDED_RULE_FAMILY`; otherwise this
    raises at import, which is the fail-closed answer — a redactor nobody has sized is a redactor the
    quarantine cannot promise to cover, and shipping it silently is how F1, F20 and F33 each happened.
    """
    bounded = []
    for pattern, _ in _REDACTORS:
        span = CS.reach(pattern)
        if span is None:
            if pattern not in _UNBOUNDED_RULE_FAMILY:
                raise RuntimeError(
                    f"redaction rule {pattern.pattern[:60]!r} has no measurable reach and is not "
                    "registered in _UNBOUNDED_RULE_FAMILY — a cut through un-redacted bytes cannot "
                    "be quarantined against it. Bound its quantifiers, or register the structural "
                    "family (delimited block / bare token run) that closes it.")
        else:
            bounded.append(span)
    return max(bounded)


_HEAD_QUARANTINE_BYTES = _head_quarantine_bytes()


def _quarantine_severed_head(buf):
    """QUARANTINE the head of a buffer that a cut through un-redacted bytes left without context.

    THE RULE, stated as a derivation rather than a list of cases, because the list was twice one case
    short. Every redaction rule in this file is LEFT-ANCHORED — the named-secret rule needs its label,
    the URL rule its scheme, the auth rule its verb, the PEM rule its BEGIN line. `_drain_bounded`
    keeps only the last `_MAX_RETAINED_BYTES`, so the cut DESTROYS left context, and a rule whose
    anchor was discarded cannot see the secret that follows it. A regex match is contiguous, so the
    surviving remnant of a straddling match is always a PREFIX of the retained buffer. Therefore:

        **nothing in that prefix can be vouched for, whatever the rules happen to be** —
        so the prefix is replaced wholesale, sized to the longest match any rule can produce.

    That is what makes this different from the repair it replaces. The old one cut back to the first
    WHITESPACE, which is exactly right for one anchor shape (the named-secret rule, where label and
    value are one token) and wrong for every rule whose anchor is a separate WORD or a separate LINE:
    `Authorization: Basic <secret>` severed inside `Basic` left the credential standing as the next
    token, and a PEM block severed inside its BEGIN line kept 43% of the key body AND lost the
    "a private key was here" marker. Sizing a repair to an anchor is an enumeration of anchors.

    TWO FAMILIES the byte count alone cannot close, handled by their STRUCTURE (see
    `_UNBOUNDED_RULE_FAMILY`):

      * BARE TOKEN RUNS (`ghp_…`, JWTs, the opaque backstop). Every arm is whitespace-free, so the
        quarantine is extended forward to the next whitespace: no partial token can outlive it,
        however long the token is.
      * DELIMITED BLOCKS (the PEM key). A closing delimiter with NO opening delimiter before it proves
        the block began in the discarded bytes — so everything above that close is key material and
        goes with it, under the PEM marker, so the receipt still says WHAT was here.

    REDACTED, NOT DELETED. A quarantined head is unattributable, so it must not be displayed — but
    silently deleting it would remove the evidence that anything was there, and where the retained
    buffer is one long token deleting would empty the receipt entirely. The marker keeps the receipt
    honest: something was here and this run cannot vouch for what.
    """
    if isinstance(buf, bytes):
        ws, marker, pem_marker = _LEADING_WS_BYTES, b"[REDACTED]", b"[REDACTED PRIVATE KEY]"
        pem_open, pem_close = _PEM_OPEN_BYTES, _PEM_CLOSE_BYTES
    else:
        ws, marker, pem_marker = _LEADING_WS, "[REDACTED]", "[REDACTED PRIVATE KEY]"
        pem_open, pem_close = CS.PEM_BLOCK_OPEN, CS.PEM_BLOCK_CLOSE
    boundary = ws.search(buf, _HEAD_QUARANTINE_BYTES)
    cut = len(buf) if boundary is None else boundary.start()
    # The block family EXTENDS the same quarantine rather than running after it, so the two cannot
    # eat each other's work: a footer with no header before it is a block that began in the discarded
    # bytes, everything above it is key material, and the region carries the PEM marker so the receipt
    # still says WHAT was here instead of losing that with the header.
    close = pem_close.search(buf)
    if close is not None:
        opened = pem_open.search(buf)
        if opened is None or opened.start() > close.start():
            cut = max(cut, close.end())
            marker = pem_marker
    return marker + buf[cut:]


def _redacted_tail(text, limit, truncated=False):
    """The bounded display tail of a capture, REDACTED ON BOTH SIDES OF THE CUT.

    `truncated` carries forward a cut that already happened UPSTREAM (the retention cut in
    `_drain_bounded`). Without it the marker is decided from this function's own input, which is
    already the survivor of that earlier cut — and redacting a severed head can shrink a 17 KB buffer
    to a few characters, so a genuinely partial capture would print as if it were the whole story.
    Same defect as deciding the marker from the post-redaction length, one boundary earlier.

    ONE SIDE IS NEVER ENOUGH, and this is not a reorder of the old `redact(_tail(...))`:

      * Cut first, redact second (what this replaces) — the cut can fall through the middle of a
        `password=hunter2` label, and the surviving `word=hunter2` matches neither the named-secret
        rule (its label was cut away) nor the opaque-run backstop (the value is 7 characters). The
        credential then lands in the COMMITTED evidence file, where the cost is a rotation and the
        exposure is permanent.
      * Redact first, cut second — closes that, but reopens the other end. The backstop is
        `\\b[A-Za-z0-9_-]{40,4096}\\b`, and a run LONGER than 4096 characters has no internal word
        boundary, so the pattern cannot match it at all. Cutting used to shrink such a run back into
        range by accident; redacting only before the cut lets a 17 KB opaque token through intact.

    So: redact the whole capture, cut to `limit`, redact again. Redaction is idempotent, so the
    second pass cannot change anything the first already handled — it exists only to catch what the
    cut newly made matchable. The cost is bounded because `_drain_bounded` caps the capture at
    `_MAX_RETAINED_BYTES` (17 KB) before this ever runs; the second pass is over `limit` characters.

    THE TRUNCATION MARKER IS DECIDED FROM THE PRE-REDACTION LENGTH. Redaction SHRINKS text, so a
    capture that really was cut can fall under `limit` once redacted. Deciding from the redacted
    length would silently drop the `…[truncated]…` signal from a receipt that is genuinely partial,
    and a reviewer would read a fragment as the whole story.
    """
    raw = text or ""
    truncated = truncated or len(raw) > limit
    kept = redact(raw)
    if len(kept) > limit:
        kept = redact(kept[-limit:])
    return "…[truncated]…\n" + kept if truncated else kept


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _is_skippable(line):
    s = line.strip()
    return not s or s.startswith("#")


def _scalar(key, raw):
    """A config scalar: quotes stripped, and an inline `# comment` stripped for structural keys only."""
    val = raw
    if key in _STRUCTURAL_KEYS:
        val = val.split("#", 1)[0]
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
    return val.strip()


def _path_list(raw):
    """`paths` as a list. Accepts a YAML flow list (`[a, b]`) or a bare comma-separated scalar.

    A block list (`-` items under `paths:`) is deliberately NOT accepted: this dependency-free scanner
    would have to guess at nesting, and silently reading a block list as EMPTY would disable the
    staleness rule — the one thing that gives this gate teeth. An unparseable `paths` is an error.
    """
    val = raw.strip()
    if val.startswith("[") and val.endswith("]"):
        val = val[1:-1]
    parts = [p.strip().strip("\"'").strip() for p in val.split(",")]
    return [p for p in parts if p]


def _bool_flag(label, raw):
    """A strict yes/no. An unrecognized value is an ERROR, never a silent False.

    `attested: true` is the one way to opt OUT of execution, so a typo must never be interpreted —
    neither into "attested" (which would let a typo disable the real check) nor quietly into "not
    attested" (which would leave the operator with a surface that cannot pass and no idea why).
    """
    val = (raw or "").strip().lower()
    if val in ("true", "yes", "on"):
        return True
    if val in ("false", "no", "off", ""):
        return False
    raise ValueError(f"{label} must be `true` or `false`, got {raw.strip()!r}")


def read_declaration(config_path):
    """Parse the `live_verification.surfaces` list out of a WORKFLOW-config.yaml.

    Dependency-free and format-specific, matching the house convention (`idc_recirculator_layers
    .read_gating`, `idc_config_keys`) — these configs ship to repos that may lack PyYAML.

    Returns the list of surface dicts; `[]` means "declared nothing" (or no block at all), which the
    caller reports as `not-declared`. Raises ValueError on a shape it cannot trust, so a malformed
    declaration becomes an ERROR rather than a silent zero-surface pass — a typo'd block must never
    read as "this repo opted out".
    """
    try:
        with open(config_path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        raise ValueError(f"cannot read {config_path}: {e}")

    # Locate the block header at any indent; ignore a COMMENTED example of it (the template ships the
    # block commented out until an operator opts in, and a commented example must never read as live).
    header = None
    for i, ln in enumerate(lines):
        if _is_skippable(ln):
            continue
        m = _KEY_LINE.match(ln)
        if m and m.group(2) == BLOCK_KEY:
            header = i
            break
    if header is None:
        return []
    base = _indent(lines[header])

    # The block body: every following line indented deeper than the header, up to the next line at or
    # left of the header's indent.
    body = []
    for ln in lines[header + 1:]:
        if _is_skippable(ln):
            body.append(ln)
            continue
        if _indent(ln) <= base:
            break
        body.append(ln)

    # Find `surfaces:` within the block.
    s_idx = None
    for i, ln in enumerate(body):
        if _is_skippable(ln):
            continue
        m = _KEY_LINE.match(ln)
        if m and m.group(2) == "surfaces":
            inline = m.group(3).strip()
            # An inline empty list (`surfaces: []`) is an explicit "no live surface" — the template's
            # shipped default, and the whole no-burden path. An empty value means a block list follows.
            if inline == "[]":
                return []
            if inline:
                raise ValueError("`live_verification.surfaces` must be `[]` or a block list of surfaces")
            s_idx = i
            break
    if s_idx is None:
        raise ValueError("`live_verification` is present but declares no `surfaces:` key")
    s_indent = _indent(body[s_idx])

    surfaces = []
    current = None
    for ln in body[s_idx + 1:]:
        if _is_skippable(ln):
            continue
        if _indent(ln) <= s_indent:
            break
        item = _ITEM_LINE.match(ln)
        if item:
            current = {}
            surfaces.append(current)
            rest = item.group(2).strip()
            if rest:
                m = _KEY_LINE.match(rest)
                if not m:
                    raise ValueError(f"unparseable surface entry: {ln.strip()!r}")
                current[m.group(2)] = _scalar(m.group(2), m.group(3))
            continue
        m = _KEY_LINE.match(ln)
        if not m:
            raise ValueError(f"unparseable line in `live_verification`: {ln.strip()!r}")
        if current is None:
            raise ValueError(f"`{m.group(2)}` appears before any `- ` surface entry")
        current[m.group(2)] = _scalar(m.group(2), m.group(3))
    return surfaces


def _confined_evidence_path(repo, name, rel):
    """Resolve a surface's evidence destination, REFUSING anything that lands outside the repo.

    TWO DISTINCT COSTS, and the second is the one that matters to this file. First, the footgun:
    `write_evidence` CREATES PARENT DIRECTORIES and opens the target with `"w"`, so a destination
    that resolves somewhere unintended is silently TRUNCATED — `evidence: ../../notes.md`, or an
    absolute path with a typo, destroys a file nobody asked this tool to touch. Second, and worse
    for a completion gate: a receipt written outside the repo — or into a gitignored corner — is
    never committed, yet the audit re-reads it happily and keeps printing `live: ok`. The proof of a
    live surface would live somewhere no reviewer can see, which is a false green with extra steps.

    THIS IS NOT A PRIVILEGE BOUNDARY and does not pretend to be one: `verify:` in the same
    operator-owned config already runs arbitrary shell, so anyone who can edit the declaration can
    already do anything. It confines the one path THIS FILE truncates on the project's behalf, so a
    mistake stays inside the repo where git can show it.

    Symlinks are resolved before the check, so a symlinked evidence directory cannot be used to step
    out. The resolved path is what gets returned, so the write lands where the check looked.
    """
    if not rel:
        raise ValueError(f"surface {name!r} has an empty `evidence:` destination")
    if os.path.isabs(rel):
        raise ValueError(f"surface {name!r} declares an ABSOLUTE `evidence:` destination ({rel!r}). "
                         f"Evidence is a committed receipt, so it must live inside the repo — declare "
                         f"a path relative to the repo root (default: {DEFAULT_EVIDENCE_DIR}/<name>.md)")
    root = os.path.realpath(repo)
    resolved = os.path.realpath(os.path.join(root, rel))
    if resolved != root and not resolved.startswith(root + os.sep):
        raise ValueError(f"surface {name!r} declares an `evidence:` destination that resolves OUTSIDE "
                         f"the repo ({rel!r} → {resolved!r}). Writing there would truncate a file "
                         f"outside this project, and a receipt the repo does not carry can never be "
                         f"reviewed — declare a path inside the repo")
    if resolved == root:
        raise ValueError(f"surface {name!r} declares the repo root itself as its `evidence:` "
                         f"destination ({rel!r}) — name a file, not the directory")
    return resolved


def surface_spec(repo, surface):
    """Validate ONE declared surface into the normalized spec the rest of this file uses.

    Every refusal here is a ValueError the caller maps to exit 2, because each one describes a
    declaration that could not be verified — and an unverifiable surface must never read as verified.
    """
    name = (surface.get("name") or "").strip()
    if not name:
        raise ValueError("a declared surface has no `name`")

    raw_paths = surface.get("paths")
    if raw_paths is None:
        raise ValueError(f"surface {name!r} declares no `paths:` — without them the staleness rule "
                         f"cannot run and the evidence would never expire")
    paths = _path_list(raw_paths)
    if not paths:
        raise ValueError(f"surface {name!r} has an empty `paths:` list")

    attested = _bool_flag(f"surface {name!r} `attested:`", surface.get("attested", ""))
    verify = (surface.get("verify") or "").strip()
    if verify and attested:
        raise ValueError(f"surface {name!r} declares BOTH `verify:` and `attested: true` — which one "
                         f"is the truth? Declare a command OR an attestation, never both")
    if not verify and not attested:
        raise ValueError(f"surface {name!r} declares no `verify:` command — IDC cannot verify a surface "
                         f"it has no way to drive. Add the command that exercises the real deployment "
                         f"(the implementing agent writes it), or, only if it genuinely cannot be "
                         f"automated, `attested: true`")

    raw_timeout = (surface.get("timeout") or "").strip()
    if raw_timeout:
        try:
            timeout = int(raw_timeout)
        except ValueError:
            raise ValueError(f"surface {name!r} has a non-numeric `timeout:` ({raw_timeout!r})")
        if timeout <= 0:
            raise ValueError(f"surface {name!r} has a non-positive `timeout:` ({timeout})")
    else:
        timeout = DEFAULT_VERIFY_TIMEOUT

    rel = (surface.get("evidence") or os.path.join(DEFAULT_EVIDENCE_DIR, f"{name}.md")).strip()
    return {
        "name": name,
        "paths": paths,
        "attested": attested,
        # TWO REPRESENTATIONS OF ONE COMMAND, and conflating them was a real bug. `verify_raw` is what
        # gets EXECUTED — the exact string the project declared, byte for byte. `verify` is the
        # REDACTED display form, and it is the only one that ever reaches disk or stderr, because a
        # config may legitimately inline a credential (`API_TOKEN=… ./probe.sh`) and an evidence file
        # is committed. Executing the redacted form instead — which is what the first cut did — runs a
        # DIFFERENT command than the one declared: `API_TOKEN=[REDACTED] ./probe.sh` fails, or worse,
        # quietly succeeds against the wrong target.
        "verify_raw": verify,
        "verify": redact(verify),
        # Redaction is lossy and therefore COLLIDES: two distinct declared commands can share one
        # redacted display string, and the audit's "is the recorded command still the declared one?"
        # rule compares display strings. The hash is taken over the RAW command, so swapping a real
        # probe for a different one that redacts identically still invalidates every old receipt. It
        # is a digest, never a preimage — the raw command is not recoverable from it.
        "verify_sha256": _command_sha(verify),
        "timeout": timeout,
        "rel": rel,
        "evidence_path": _confined_evidence_path(repo, name, rel),
    }


# ── the run witness: what makes "a typed claim does not satisfy this gate" TRUE ──────────────────
# THE HOLE THIS CLOSES. Every field the audit checked — `mode`, the command, its sha256, `exit_code`,
# the commit — is data anyone can TYPE. The declared command and its digest are derivable from the
# config, and the commit is `git rev-parse HEAD`. So a hand-written receipt that merely MIMICKED the
# shape of a real one passed the audit with `live: ok` while the surface's actual verify command
# exited 1 — the exact "typed claim read as a measurement" failure this whole gate exists to refuse,
# reproduced inside the gate itself.
#
# WHY NO AMOUNT OF CHECKING THE RECEIPT COULD FIX IT. The receipt is a COMMITTED, portable file, so
# every value in it must be one any reader can recompute — and anything a reader can recompute, a
# forger can write. A signature does not help either: the key would have to travel with the repo to
# stay verifiable, and a key in the repo is not a secret. The receipt alone can therefore never
# establish that a run happened. That is a property of committed evidence, not an oversight.
#
# SO THE PROOF LIVES WHERE IT CANNOT BE COMMITTED. A real `--run` also records the run in the repo's
# GIT DIRECTORY, which git itself never tracks and no diff or PR can carry. The audit requires the
# receipt and this witness to AGREE. A receipt that arrived by being typed — into the working tree, or
# into a branch someone pushed — has no witness behind it and is refused by name.
#
# THE BOUNDARY, STATED. This proves "this working copy really executed that command against that
# commit". It is not a defence against someone who edits the git directory by hand; nothing local
# could be. It is exactly the defence the shipped instruction needs: writing the evidence file is no
# longer sufficient, so `agents/idc-build.md`'s "never hand-write an evidence record — a typed claim
# does not satisfy this gate" is now a true statement about behaviour rather than a request.
#
# THE COST, STATED. A receipt is only trusted in a working copy that ran it. A fresh clone that has a
# committed receipt but has never run the check reports a GAP naming that reason, and `--run` clears
# it. That is the honest answer: the receipt records that the surface passed somewhere, and this
# working copy has not seen it happen.
_WITNESS_REL = os.path.join("idc", "live-runs.json")
_WITNESS_VERSION = 1


def _witness_path(repo):
    """`<git-common-dir>/idc/live-runs.json` — inside the git directory, so git can never carry it.

    THE COMMON DIR, NOT THIS CHECKOUT'S. `--absolute-git-dir` resolves inside a LINKED WORKTREE to
    `<main>/.git/worktrees/<name>`, which is private to that worktree and deleted with it. IDC's own
    build topology makes that the normal case, not an exotic one: the claude adapter pre-creates a
    worktree per work item, `idc:idc-build` runs the wave-close `--run` inside it, and
    `idc_autorun_drain.py` audits from the MAIN checkout after the merge. With a per-worktree witness
    that sequence reported a false `live: gap` on every worktree-built wave — accusing a genuine
    measurement of being hand-written — and `git worktree remove` then destroyed the proof for good.

    `--git-common-dir` is the SHARED `.git`, which every linked worktree agrees on. The security
    property is exactly as strong: git never carries `.git` itself in a commit, a diff, a PR or a
    clone, so a receipt that travels still arrives with no witness. It returns a RELATIVE path (`.git`)
    when git is run from the repo root, so it is resolved against `repo`.
    """
    rc, git_dir = _git(repo, "rev-parse", "--git-common-dir")
    if rc != 0 or not git_dir:
        _fail(f"{repo}: the git directory could not be resolved, so a real run cannot be "
              f"distinguished from a typed receipt")
    if not os.path.isabs(git_dir):
        git_dir = os.path.join(repo, git_dir)
    return os.path.join(os.path.normpath(git_dir), _WITNESS_REL)


def _read_witnesses(repo):
    """Every recorded run in this working copy, keyed by surface name. Unreadable/corrupt reads as
    EMPTY — which withholds trust rather than granting it, so damaging this file can only ever cost a
    re-run, never manufacture a pass."""
    try:
        with open(_witness_path(repo), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict) or data.get("version") != _WITNESS_VERSION:
        return {}
    runs = data.get("runs")
    return runs if isinstance(runs, dict) else {}


def record_witness(repo, spec, rc, commit):
    """Record that THIS working copy really executed this surface's command. Called only by `--run`.

    A failure to record is an ERROR, not a shrug: the run happened but cannot be proven later, and the
    audit would report a gap with a misleading reason. Better to say so now, while the operator is
    still watching the run they started.
    """
    path = _witness_path(repo)
    runs = _read_witnesses(repo)
    runs[spec["name"]] = {
        "command_sha256": spec["verify_sha256"],
        "commit": commit,
        "exit_code": rc,
        "ran_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"version": _WITNESS_VERSION, "runs": runs}, fh, sort_keys=True)
        os.replace(tmp, path)
    except OSError as e:
        _fail(f"surface {spec['name']!r}: the run could not be recorded in the git directory "
              f"({e}) — the command ran, but nothing would be able to tell that receipt apart from a "
              f"hand-written one")


def _witness_gap(repo, spec, payload):
    """The reason this receipt is not corroborated by a real run here, or None when it is."""
    entry = _read_witnesses(repo).get(spec["name"])
    if not isinstance(entry, dict):
        return (f"{spec['rel']} claims an executed run, but this working copy has no record of ever "
                f"running `{spec['verify']}` — a receipt that was hand-written, or that arrived in a "
                f"commit, is not a measurement; run `idc_live_check.py --repo . --run`")
    for field, claimed in (("command_sha256", payload.get("command_sha256")),
                           ("commit", payload.get("commit")),
                           ("exit_code", payload.get("exit_code"))):
        recorded = entry.get(field)
        claimed = claimed.strip() if isinstance(claimed, str) else claimed
        if recorded != claimed:
            return (f"{spec['rel']} disagrees with what this working copy actually ran: the receipt "
                    f"says {field}={claimed!r}, the recorded run says {recorded!r} — re-run "
                    f"`idc_live_check.py --repo . --run`")
    return None


_TOKEN_SPLIT = re.compile(r"[\s;|&()<>]+")


def verifier_paths(repo, spec):
    """The repo-relative files the VERIFY COMMAND ITSELF is made of, for the freshness rule.

    THE GAP THIS CLOSES. `paths:` names the code the surface is made of, and the expiry rule watches
    it. But the verify command is code too, and it was watched by nothing: the shipped example
    declares `paths: [services/, web/, infra/]` and `verify: bash scripts/verify-live-web.sh`, so
    editing the PROBE — weakening an assertion, deleting a step, commenting out the chat check —
    left every receipt it had produced looking current. The receipt says "this command passed", and
    the command silently became a different command. `command_sha256` catches a change to the
    declared STRING; nothing caught a change to the file that string runs.

    Derived rather than declared, because asking projects to list their probe's files again would
    just be a second thing to forget. Any token in the raw command that resolves to a real file
    inside the repo counts — that is `scripts/verify-live-web.sh` in the example, and a bare `curl`
    or `--fail` resolves to nothing and is ignored. Deliberately shallow: it does not chase what the
    script itself sources, so it is a floor on freshness, not a proof of closure.
    """
    root = os.path.realpath(repo)
    found = []
    for tok in _TOKEN_SPLIT.split(spec.get("verify_raw") or ""):
        tok = tok.strip().strip("'\"")
        if not tok or tok.startswith("-"):
            continue
        cand = tok if os.path.isabs(tok) else os.path.join(root, tok)
        try:
            if not os.path.isfile(cand):
                continue
            rel = os.path.relpath(os.path.realpath(cand), root)
        except (OSError, ValueError):
            continue
        if not rel.startswith(".." + os.sep) and rel != ".." and rel not in found:
            found.append(rel)
    return found


class Watched(NamedTuple):
    """The two halves of "the files this receipt's meaning depends on", and their union."""
    declared: list      # the surface's `paths:` — the code the surface is made of
    probe: list         # the verify command's own files — the code that decided it works

    @property
    def all(self):
        return self.declared + self.probe


def watched_paths(repo, spec):
    """THE ONE DEFINITION of "the files this receipt's meaning depends on": the surface's declared
    `paths:` plus the verify command's own files.

    ONE CONCEPT, ONE FUNCTION, because two rules read it and they had drifted apart. Both the EXPIRY
    rule (has anything landed since the run?) and the ATTRIBUTION rule (is the tree the commit the
    receipt names?) are asking the same question about the same set — "is the code this receipt
    describes still the code that is here?" — and the freshness rule was taught about the probe while
    the dirtiness rule was not. The result was a receipt reading `live: ok` for a probe that HEAD had
    never contained: weaken the verify script, leave the edit UNCOMMITTED, and `git log` (freshness)
    cannot see it while `git status` (dirtiness) was not looking at it.

    IT RETURNS THE TWO HALVES, not one flat list, because the claim above has to be TRUE of the code
    and not merely of a docstring. The first version of this function had exactly one caller and the
    attribution rule re-derived the identical composition inline — so the two agreed by coincidence of
    authorship, which is the very drift it was introduced to end. The halves matter more now than they
    did then: the two consumers apply genuinely DIFFERENT rules to them (expiry asks `git log` about
    the union; attribution asks a tracked-only status of the declared half and content identity with
    HEAD of the probe half), and inline re-derivation would be a live drift rather than a latent one.
    """
    declared = list(spec["paths"])
    return Watched(declared, [p for p in verifier_paths(repo, spec) if p not in declared])


def _status_paths(repo, untracked, paths):
    """The paths under `paths` that `git status` reports as changed, or [] when git could not answer.

    PARSED BY SPLITTING OFF THE STATUS FIELD, not by a fixed `line[3:]` offset. A porcelain line for an
    unstaged change begins with a SPACE (` M scripts/verify.sh`), and `_git` strips its whole stdout —
    so the first line arrives one character shorter than the rest and a fixed slice ate the first
    letter of its path. The refusal then named `cripts/verify.sh`, a file the operator cannot find.
    """
    if not paths:
        return []
    rc, out = _git(repo, "status", "--porcelain", f"--untracked-files={untracked}", "--", *paths)
    if rc != 0:
        return []
    return [ln.split(None, 1)[-1].strip() for ln in out.splitlines() if ln.split()]


def _unattributable_probe_paths(repo, probe):
    """The verify command's own files whose CONTENT is not the content HEAD holds at that path.

    THE QUESTION, ASKED DIRECTLY. The receipt claims: *this probe, at commit C, produced this exit
    code*. That is true iff the bytes that ran ARE the bytes commit C holds at that path. So compare
    them — the blob HEAD names against the blob the working file hashes to — and ask nothing else.

    THIS REPLACED A `git status` SCAN, and that is the whole point. Asking `git status` is asking
    about GIT'S REPORTING POLICY, which is a moving target with its own exceptions:
    `--untracked-files=no` hid a probe replaced wholesale by an untracked file, and
    `--untracked-files=all` still hides an IGNORED one, because `git status` does not report ignored
    files AT ALL — so one `.gitignore` line, or simply a probe living under an already-ignored
    `node_modules/.bin` or `.venv/bin`, restored the identical false green: a receipt reading
    `live: ok` at a commit containing no probe, while the honest probe exits 1. Each fix added the
    reporting mode somebody had just been bitten by, and the next one was always waiting. Content
    identity has no case structure to be one case short of: ignored, untracked, staged,
    `assume-unchanged`, `skip-worktree` and wholesale replacement all reduce to the same comparison.

    A path git cannot answer for — absent from HEAD, unhashable, a git that will not run — is
    UNATTRIBUTABLE, never clean: an unreadable truth is a refusal (rule B), and "HEAD holds no such
    file" is exactly the wholesale-replacement case this has to catch.
    """
    out = []
    for rel in probe:
        rc_head, head_oid = _git(repo, "rev-parse", f"HEAD:{rel}")
        rc_work, work_oid = _git(repo, "hash-object", "--", os.path.join(repo, rel))
        if rc_head != 0 or rc_work != 0 or not head_oid or head_oid != work_oid:
            out.append(rel)
    return out


def _dirty_paths(repo, spec):
    """The files this receipt's meaning depends on that differ from HEAD right now, if any.

    WHY A RUN OVER A DIRTY TREE CANNOT BE ATTRIBUTED TO HEAD. The verify command executes against the
    WORKING TREE, and the receipt records `commit: <HEAD>`. When the two disagree, the receipt claims
    a code state that was never the one exercised: the audit's whole expiry rule then reasons about
    commits, while what actually passed was an uncommitted edit that may never be committed at all.
    That is a false green with a real deployment behind it.

    THE PROBE IS PART OF THE SET (`watched_paths`), and the two halves are asked DIFFERENT
    QUESTIONS for a reason that is not symmetry:

      * The DECLARED paths get a TRACKED-ONLY `git status`. A run inevitably dirties the tree by
        writing its own evidence receipt, and repos carry all sorts of unrelated scratch; neither says
        anything about whether the code backing this surface was the code that ran. Including
        untracked files here would make the second run of every surface refuse. That is a POLICY, and
        it is written down here so it is not mistaken for a missed case: an untracked file appearing
        under `services/` is not evidence that the code behind the surface changed. (Ignored files are
        a strict subset of untracked and sit outside the same policy for the same reason; and ignoring
        a TRACKED file is a no-op in git, so no declared file can hide that way.)
      * The VERIFY COMMAND'S OWN FILES are asked for CONTENT IDENTITY with HEAD — see
        `_unattributable_probe_paths`. The probe is source, there is no evidence-receipt case to
        protect, and every way of hiding a changed probe from `git status` reduces to one comparison.
    """
    watched = watched_paths(repo, spec)
    dirty = _status_paths(repo, "no", watched.declared)
    for p in _unattributable_probe_paths(repo, watched.probe):
        if p not in dirty:
            dirty.append(p)
    return dirty


def _git(repo, *args):
    """(rc, stdout) for a git call in `repo`; a git that cannot be run at all is an ERROR."""
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        _fail(f"git could not be run in {repo} ({e})")
    return r.returncode, (r.stdout or "").strip()


# How much of the child's output is ever HELD IN MEMORY at once. Deliberately a little larger than
# MAX_BODY_CHARS (and in bytes, so multi-byte characters cannot smuggle the character count past the
# bound) so that `_tail` still sees an over-limit input and adds its own truncation marker exactly as
# before — the retained slack is what keeps the "…[truncated]…" signal honest.
_MAX_RETAINED_BYTES = MAX_BODY_CHARS * 4 + 1024
_READ_CHUNK = 65536


def _drain_bounded(proc, timeout):
    """Drain the child's merged stdout/stderr to EOF, RETAINING ONLY THE LAST `_MAX_RETAINED_BYTES`.

    WHY NOT `communicate()`. `communicate` returns EVERYTHING the child printed, so a verify script
    that emits a gigabyte is a gigabyte in this process's memory. The existing bounds (`_tail`,
    MAX_BODY_CHARS) apply only to what gets WRITTEN — by the time they run the whole capture is already
    resident, and the timeout can no longer help either, because the command has exited. The bound has
    to be on the READ.

    WHY IT STILL DRAINS. Retaining a tail is not the same as reading less: the pipe must keep being
    emptied or the child BLOCKS on a full pipe buffer and dies on the timeout instead of finishing.
    So this reads everything and forgets all but the tail — memory is bounded, behavior is not changed.

    The deadline is enforced with `select` rather than a blocking read, so a child that goes silent
    without exiting still times out (a plain `read()` would wait for output that never comes). Raises
    `subprocess.TimeoutExpired` on the deadline, so the caller's existing timeout arm — kill the process
    group, invalidate the stale receipt, report INDETERMINATE — is reached unchanged.

    THE RETENTION CUT IS A REDACTION BOUNDARY, and that is why `_quarantine_severed_head` is here.
    Keeping only the last N bytes means the buffer's HEAD has no left-hand context whenever the child
    printed more than N — and this cut happens BEFORE anything is redacted, so every rule in the file,
    all of them left-anchored, is blind to whatever the cut severed: a `password=` label, an
    `Authorization: Basic` verb, a PEM BEGIN line. The credential then reaches the committed receipt.
    Redacting at every trim instead would put a whole-buffer pass on every 64 KB chunk — for a child
    that prints a gigabyte that is ~16k passes over 17 KB, which is the same "a check that hangs is a
    check that gets removed" failure the bound exists to prevent. Quarantining the head is O(1) and
    does not depend on which rules exist: see `_quarantine_severed_head` for the derivation.

    Returns the decoded tail; the caller applies `_redacted_tail` to it as before."""
    deadline = time.time() + timeout
    kept = b""
    overflowed = False
    try:
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(proc.args, timeout)
            ready, _, _ = select.select([proc.stdout], [], [], remaining)
            if not ready:
                raise subprocess.TimeoutExpired(proc.args, timeout)
            chunk = proc.stdout.read1(_READ_CHUNK)
            if not chunk:
                break  # EOF — every writer on the pipe has closed it
            kept += chunk
            if len(kept) > _MAX_RETAINED_BYTES:
                overflowed = True
                kept = kept[-_MAX_RETAINED_BYTES:]
    finally:
        try:
            proc.stdout.close()
        except OSError:  # pragma: no cover — defensive
            pass
    # EOF does not by itself mean the child has reaped; wait for the real exit status within whatever
    # is left of the same deadline, so `proc.returncode` is never read as None.
    proc.wait(timeout=max(0.1, deadline - time.time()))
    # Only when the retention cut actually fired: with nothing discarded there is no severed head, and
    # redacting the first token of a SHORT capture would throw away output the reader needs.
    if overflowed:
        kept = _quarantine_severed_head(kept)
    # The overflow travels WITH the text, because it is a fact about the capture that the text can no
    # longer be asked for — `_quarantine_severed_head` may have shrunk 17 KB to ten characters.
    return kept.decode("utf-8", "replace"), overflowed


def run_verify(repo, spec, commit):
    """EXECUTE one surface's verify command in the repo root. Returns (exit_code, redacted_output, secs).

    The command is a project-owned shell string, so it runs through the shell — that is the whole point
    of the contract (IDC never learns what a browser or an HTTP client is). On `shell=True`: the string
    comes from the governed repo's OWN committed `WORKFLOW-config.yaml`, which sits at exactly the same
    trust level as the repo's Makefile, its test runner, and the scripts the pipeline already executes.
    There is no untrusted input here to inject through — anyone who can edit that config can already
    commit a script. It is never built by concatenating a value from a board, a PR, or a model. Three
    details are load-bearing:

      * `start_new_session=True` + a process-GROUP kill on timeout. A verify script typically spawns
        children (a browser, a dev server, a curl loop); killing only the shell would orphan them and
        leave a hung deployment probe running on the operator's machine forever.
      * `stdin=DEVNULL`. A script that stops to ask a question must die on its own timeout, not sit
        waiting for a human who is asleep — this gate exists precisely to stop paging people.
      * The child inherits the ambient environment (it NEEDS real credentials to reach a real
        deployment), but that environment is never read, printed, or recorded here. Only the child's
        own output is captured, and it is redacted before it goes anywhere.

    A timeout, or a shell that cannot execute the command at all (126 "not executable" / 127 "not
    found"), is INDETERMINATE (exit 2): the CHECK is broken, which is a different fact from the product
    being broken, and reporting it as a product gap would send the pipeline to fix the wrong thing.

    EVERY INDETERMINATE PATH INVALIDATES THE OLD RECEIPT FIRST (`_invalidate`), and this is the whole
    reason `commit` is a parameter. Exiting 2 without touching the evidence file leaves YESTERDAY'S
    PASSING receipt on disk — and the fast AUDIT path is a separate process that reads only that file.
    So a `--run` that timed out, or whose verify script had just been deleted, would exit 2 while the
    drain and the Stop gate went on reporting `live: ok` from a receipt no longer backed by anything.
    That is precisely the false-green this gate exists to prevent, and it is worse than no gate,
    because a stale pass is BELIEVED. The receipt is replaced with an `indeterminate` record, which the
    audit refuses in its own right (exit 2) until a real run overwrites it.
    """
    started = time.time()
    try:
        # `verify_raw`, never `verify`: the redacted form is for the RECORD, and running it would run a
        # different command than the project declared (see `surface_spec`).
        # BINARY pipe on purpose: `_drain_bounded` selects on the raw fd and retains a byte tail, then
        # decodes once at the end. A text-mode wrapper would buffer decoded characters where `select`
        # cannot see them.
        proc = subprocess.Popen(spec["verify_raw"], shell=True, cwd=repo, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                start_new_session=True)
    except (OSError, ValueError) as e:
        _invalidate(spec, commit, f"the verify command could not be started ({e})")
        _fail(f"surface {spec['name']!r}: the verify command could not be started ({e})")
    try:
        out, overflowed = _drain_bounded(proc, spec["timeout"])
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        _invalidate(spec, commit, f"the verify command did not finish within {spec['timeout']}s")
        _fail(f"surface {spec['name']!r}: the verify command did not finish within "
              f"{spec['timeout']}s — a hung probe proves nothing (raise `timeout:` or make the check "
              f"terminate)")
    except (OSError, subprocess.SubprocessError) as e:  # pragma: no cover — defensive
        _kill_group(proc)
        _invalidate(spec, commit, f"the verify command could not be run ({e})")
        _fail(f"surface {spec['name']!r}: the verify command could not be run ({e})")
    duration = round(time.time() - started, 1)
    # REDACT ON BOTH SIDES OF THE DISPLAY CUT. Neither order alone is safe — cutting first can sever a
    # credential's own label, and redacting only first cannot see an opaque run too long to carry a word
    # boundary. `_redacted_tail` does both passes and explains why. (The full capture lives only in this
    # local, is already bounded by `_drain_bounded`, and dies with the call.)
    output = _redacted_tail(out or "", MAX_BODY_CHARS, truncated=overflowed)
    if rc in (126, 127):
        _invalidate(spec, commit,
                    f"the verify command could not be executed (shell exit {rc} — not found or not "
                    f"executable)")
        _fail(f"surface {spec['name']!r}: the verify command could not be executed (shell exit {rc} — "
              f"not found or not executable). A missing check is INDETERMINATE, never a pass")
    # `output` — the bounded, twice-redacted tail — is the only thing any caller gets. `out` itself is
    # never returned, printed, or written; it dies with this frame.
    return rc, output, duration


def _kill_group(proc):
    """SIGKILL the child's whole process group; never let cleanup raise over the real verdict."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.communicate(timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass


def write_evidence(spec, rc, output, commit, duration, mode=MODE_EXECUTED, note=None):
    """Regenerate the surface's evidence record from a REAL run. Written on failure too, deliberately.

    Writing only on success would leave yesterday's PASSING receipt in place after today's run failed —
    the audit would keep reporting `live: ok` while the command that just ran said otherwise. The
    record always describes the LAST execution, so the fast audit and a fresh `--run` can never
    disagree. `mode=MODE_INDETERMINATE` (with `rc=None`) writes the same record for a run that could
    not establish anything at all — see `_invalidate`.

    THE SINGLE WRITE DOOR NEUTRALIZES CAPTURED TEXT. Everything derived from the verify command's own
    output — the body, the one-line `observed` digest — is defused here rather than at the call site,
    so no caller can forget and reopen the forged-marker hole `neutralize` documents.
    """
    body = _tail(neutralize(output.strip()), MAX_BODY_CHARS)
    observed = (" ".join(_tail(neutralize(output.strip()), MAX_OBSERVED_CHARS).split())
                or f"(no output; exit {rc})")
    if note:
        observed = f"{note} — {observed}" if observed else note
    payload = {
        "surface": spec["name"],
        "mode": mode,
        "command": neutralize(spec["verify"]),
        # The identity of the command that ran, immune to redaction collisions (see `surface_spec`).
        "command_sha256": spec["verify_sha256"],
        "exit_code": rc,
        "commit": commit,
        "ran_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_s": duration,
        "observed": observed,
    }
    if mode == MODE_INDETERMINATE:
        payload["reason"] = note or "the verify command did not produce a verdict"
    verdict = ("INDETERMINATE" if mode == MODE_INDETERMINATE
               else f"{rc} ({'PASS' if rc == 0 else 'FAIL'})")
    doc = (
        f"# Live verification — {spec['name']}\n\n"
        "GENERATED by `idc_live_check.py --run`. Do not hand-edit: the next run overwrites this file, "
        "and a hand-written claim does not satisfy the gate.\n\n"
        f"- **surface:** {spec['name']}\n"
        f"- **command:** `{neutralize(spec['verify'])}`\n"
        f"- **exit code:** {verdict}\n"
        f"- **commit:** `{commit}`\n"
        f"- **ran at:** {payload['ran_at']}\n"
        f"- **duration:** {duration}s\n\n"
        + (f"> **This run established nothing.** {payload['reason']}. The previous receipt has been "
           f"REPLACED rather than left in place, so no stale pass survives an indeterminate run; the "
           f"audit reports an error until `idc_live_check.py --repo . --run` produces a real "
           f"verdict.\n\n" if mode == MODE_INDETERMINATE else "")
        + "## Output (bounded; credentials redacted; marker-like text escaped)\n\n"
        "```\n" + (body if body else "(no output)") + "\n```\n\n"
        # ALWAYS LAST IN THE FILE, and `read_evidence` anchors to the last marker for exactly that
        # reason: captured output is printed ABOVE this line, so a marker a verify script planted can
        # never be the one that is read.
        f"<!-- {MARKER_SENTINEL}: {json.dumps(payload, sort_keys=True)} -->\n"
    )
    try:
        parent = os.path.dirname(spec["evidence_path"])
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(spec["evidence_path"], "w", encoding="utf-8") as fh:
            fh.write(doc)
    except OSError as e:
        # The record could not be replaced. A stale PASSING receipt must not survive that, so remove it
        # outright — "nobody has verified this yet" is an honest state; "verified, yesterday, by a run
        # that has since been overwritten by a run that established nothing" is not.
        try:
            os.remove(spec["evidence_path"])
        except OSError:
            pass
        _fail(f"surface {spec['name']!r}: could not write the evidence record "
              f"{spec['rel']} ({e})")


def _invalidate(spec, commit, reason):
    """Replace a surface's receipt with an INDETERMINATE record, before failing the run.

    Called on every path where the command produced no verdict (see `run_verify`). The old receipt is
    never simply left alone: the fast audit reads that file in a separate process and would keep
    answering `live: ok` from it.
    """
    write_evidence(spec, None, "", commit, 0, mode=MODE_INDETERMINATE, note=reason)


def read_evidence(path):
    """`(payload, None)` for a valid marker, `(None, reason)` for a MISSING one.

    A CORRUPT marker (unparseable JSON, a non-object, a missing/blank required key) is not "missing" —
    it exits 2 directly. Damaging an evidence file must never be a way to get a clean answer, and it
    must never be confused with the honest "nobody has verified this yet" state.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None, f"no evidence record at {path}"
    # THE LAST MARKER, NEVER THE FIRST. `write_evidence` always emits the generated marker as the final
    # line, and everything a verify script printed sits ABOVE it. Reading the first match let captured
    # output shadow the real verdict: a script that failed could print its own marker claiming exit 0,
    # and the audit would read the forgery and never reach the truth. (`neutralize` defuses such text
    # at write time as well — two defenses, so neither one silently becomes load-bearing alone.)
    matches = list(EVIDENCE_MARKER.finditer(text))
    if not matches:
        return None, f"{path} carries no {MARKER_SENTINEL} marker"
    m = matches[-1]
    try:
        payload = json.loads(m.group(1))
    except json.JSONDecodeError as e:
        _fail(f"{path} has an unparseable idc-live-evidence marker ({e})")
    if not isinstance(payload, dict):
        _fail(f"{path} idc-live-evidence marker is not a JSON object "
              f"(got {type(payload).__name__})")
    for key in REQUIRED_EVIDENCE_KEYS:
        val = payload.get(key)
        if not isinstance(val, str) or not val.strip():
            _fail(f"{path} idc-live-evidence marker has no non-empty `{key}`")
    return payload, None


def audit_surface(repo, spec):
    """`(reason, mode)` — `reason` is None when this surface's evidence is present, current and honest.

    Read-only: this never executes anything. `mode` is the verified provenance of a clean answer
    (`executed` or `attested`) so the caller can print a verdict that cannot pass an attestation off as
    a measurement.
    """
    payload, missing = read_evidence(spec["evidence_path"])
    if missing:
        cure = ("record the attestation" if spec["attested"]
                else f"run `idc_live_check.py --repo . --run` to execute `{spec['verify']}`")
        return f"{missing} — {cure}", None
    if payload["surface"].strip() != spec["name"]:
        return (f"{spec['rel']} is evidence for surface {payload['surface'].strip()!r}, "
                f"not {spec['name']!r}"), None

    mode = payload.get("mode")
    mode = mode.strip() if isinstance(mode, str) else ""

    # A run that established nothing stays INDETERMINATE for every later reader. This is what makes the
    # invalidation in `run_verify` mean something: the fast audit is a separate process that only ever
    # sees this file, so the record must carry the "no verdict" fact forward itself. Exit 2, never a
    # gap — the check is broken, which is a different fact from the product being broken.
    if mode == MODE_INDETERMINATE:
        why = payload.get("reason")
        why = why.strip() if isinstance(why, str) and why.strip() else "no reason recorded"
        _fail(f"surface {spec['name']!r}: the last run established nothing ({why}) — re-run "
              f"`idc_live_check.py --repo . --run`; until it produces a real verdict this surface is "
              f"unverified, not verified")

    if spec["attested"]:
        # The escape hatch. A record for an attested surface must SAY it is an attestation, so an
        # executed receipt can never be quietly repurposed as one (or the reverse).
        if mode != MODE_ATTESTED:
            return (f"{spec['rel']} is not an attestation record (`mode` is {mode or 'absent'!r}) — an "
                    f"`attested: true` surface needs a record with \"mode\": \"attested\""), None
    else:
        # THE POINT OF THIS GATE. A typed claim is not a run. A record with no executed provenance is
        # reported as never executed, whatever prose it carries.
        if mode != MODE_EXECUTED:
            return (f"{spec['rel']} records no EXECUTED verification (`mode` is {mode or 'absent'!r}) — a "
                    f"hand-written claim does not satisfy a surface that declares a `verify:` command; "
                    f"run `idc_live_check.py --repo . --run`"), None
        command = payload.get("command")
        if not isinstance(command, str) or not command.strip():
            _fail(f"{spec['rel']} claims an executed run but names no `command`")
        exit_code = payload.get("exit_code")
        if not isinstance(exit_code, int) or isinstance(exit_code, bool):
            _fail(f"{spec['rel']} claims an executed run but has no integer `exit_code`")
        # The recorded command must still be the DECLARED one. Swapping a real probe for `true` after
        # the fact invalidates every receipt the old command produced, instead of inheriting its green.
        if command.strip() != spec["verify"]:
            return (f"{spec['rel']} records a different command than the surface now declares "
                    f"(recorded {command.strip()!r}, declared {spec['verify']!r}) — re-run it"), None
        # …and the display strings matching is not enough, because redaction is lossy: two different
        # declared commands can render to the same redacted text. The digest is over the RAW command,
        # so it separates them. A receipt with no digest predates this rule and cannot identify what it
        # ran, which is a reason to re-run, not a reason to trust it.
        recorded_sha = payload.get("command_sha256")
        if not isinstance(recorded_sha, str) or not recorded_sha.strip():
            return (f"{spec['rel']} records no `command_sha256`, so the command it ran cannot be "
                    f"identified (a redacted command string is not unique) — re-run "
                    f"`idc_live_check.py --repo . --run`"), None
        if recorded_sha.strip() != spec["verify_sha256"]:
            return (f"{spec['rel']} records a different command than the surface now declares (the "
                    f"recorded command digest does not match) — re-run it"), None
        if exit_code != 0:
            return (f"the verify command FAILED (exit {exit_code}) on the last run — this is a finding "
                    f"about the product; read {spec['rel']} for the captured output, fix it, and "
                    f"re-run"), None

    commit = payload["commit"].strip()
    # A FULL OBJECT NAME, checked before git ever sees it. Git resolves symbolic names, so a receipt
    # naming `HEAD` (or a branch, or `HEAD~0`) satisfies every freshness rule below by construction:
    # it exists, it is an ancestor of HEAD, and nothing has landed since. Only a 40-hex sha pins a
    # receipt to one immutable code state, which is the entire basis of the expiry rule.
    if not _FULL_SHA.match(commit):
        return (f"{spec['rel']} names {commit!r} as the verified commit, which is not a full 40-hex "
                f"object name — a receipt must pin one immutable commit, not a moving reference; "
                f"re-run `idc_live_check.py --repo . --run`"), None
    rc, _ = _git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}")
    if rc != 0:
        return f"evidence names commit {commit[:12]} which does not exist in this repo", None
    # The evidence must describe something that actually SHIPPED. A commit that is not an ancestor of
    # HEAD is on an unmerged branch (or was rewritten away): a run observed there proves nothing
    # about what is on the mainline now.
    rc, _ = _git(repo, "merge-base", "--is-ancestor", commit, "HEAD")
    if rc != 0:
        return (f"evidence names commit {commit[:12]}, which is not an ancestor of HEAD "
                f"(unmerged or rewritten) — it does not describe what shipped"), None
    # THE EXPIRY. Anything landing on the surface's own paths since the run invalidates it, because the
    # thing that was proven working is no longer the thing that is deployed.
    # The freshness set is `watched_paths` — the declared paths PLUS the verify command's own files: a
    # probe that has been weakened since the run proves nothing about the run, and `command_sha256`
    # only notices a change to the declared STRING, never to the script that string executes. The
    # dirty-tree refusal reads the SAME set from the SAME function, so the two can never drift again.
    watched = watched_paths(repo, spec).all
    rc, out = _git(repo, "log", "--format=%H", f"{commit}..HEAD", "--", *watched)
    if rc != 0:
        _fail(f"git log over surface {spec['name']!r} paths failed")
    if out:
        n = len(out.splitlines())
        cure = ("re-attest it" if spec["attested"] else "re-run `idc_live_check.py --repo . --run`")
        return (f"evidence is STALE — {n} commit(s) have landed on {', '.join(watched)} since "
                f"{commit[:12]}; {cure}"), None
    # THE GENUINENESS CHECK, LAST. Every rule above interrogates what the receipt SAYS, and each has
    # its own reason a reader can act on; this one asks the question the receipt cannot answer about
    # itself — did a run actually happen here? It runs last on purpose, so a receipt that is stale, or
    # names a dead commit, or records a failing exit still reports THAT, rather than being masked by a
    # provenance complaint. An `attested: true` surface is exempt by definition: its record is
    # hand-written on purpose, and the verdict line already says so out loud.
    if not spec["attested"]:
        witness_gap = _witness_gap(repo, spec, payload)
        if witness_gap:
            return witness_gap, None
    return None, (MODE_ATTESTED if spec["attested"] else MODE_EXECUTED)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="idc_live_check.py",
        description="Verify each DECLARED live surface by RUNNING the project's own verify command "
                    "(--run), or audit that a current machine-generated receipt exists (default). "
                    "No declaration means no gate. Fail-closed.")
    ap.add_argument("--repo", default=".", help="the governed repo root (default: cwd)")
    ap.add_argument("--config", default=None,
                    help=f"path to {CONFIG_BASENAME} (default: <repo>/{CONFIG_BASENAME})")
    ap.add_argument("--run", action="store_true",
                    help="EXECUTE each declared surface's `verify:` command and regenerate its evidence "
                         "record, then audit. Without this the check is read-only and executes nothing "
                         "(what the drain and the Stop gate call, so they stay fast).")
    args = ap.parse_args(argv)
    repo = os.path.abspath(args.repo)
    config_path = args.config or os.path.join(repo, CONFIG_BASENAME)

    # An ABSENT config is not-declared (a repo that never ran /idc:init, or the check pointed at the
    # wrong root) — but an EXPLICIT --config that cannot be read is a usage error the caller must see,
    # never a silent pass.
    if not os.path.isfile(config_path):
        if args.config:
            _fail(f"--config {config_path} does not exist")
        print("live: not-declared")
        sys.exit(0)

    try:
        surfaces = read_declaration(config_path)
    except ValueError as e:
        _fail(str(e))

    # THE NO-BURDEN PATH, and it returns BEFORE anything can be executed: a repo that declares no
    # surface never runs a command, even under --run.
    if not surfaces:
        print("live: not-declared")
        sys.exit(0)

    rc, _ = _git(repo, "rev-parse", "--git-dir")
    if rc != 0:
        _fail(f"{repo} is not a git repository — evidence freshness cannot be established")

    try:
        specs = [surface_spec(repo, s) for s in surfaces]
    except ValueError as e:
        _fail(str(e))

    if args.run:
        rc, head = _git(repo, "rev-parse", "HEAD")
        if rc != 0 or not head:
            _fail(f"{repo} has no HEAD commit — a run cannot be attributed to any code state")
        for spec in specs:
            if spec["attested"]:
                sys.stderr.write(f"idc-live-check: {spec['name']} — attested: true, nothing to execute "
                                 f"(the record is hand-written)\n")
                continue
            # A RUN IS ATTRIBUTED TO A COMMIT, so it may not start from a tree that is not that
            # commit. The command executes against the WORKING TREE while the receipt records HEAD;
            # if the surface's own code is uncommitted, the receipt would claim a code state that was
            # never exercised, and every expiry rule downstream reasons about commits. Refusing here
            # is INDETERMINATE, not a gap: nothing is known about the product, only that the run
            # could not be honestly attributed. Committing the work and re-running clears it.
            dirty = _dirty_paths(repo, spec)
            if dirty:
                shown = ", ".join(dirty[:5]) + (f" (+{len(dirty) - 5} more)" if len(dirty) > 5 else "")
                _invalidate(spec, head,
                            f"the surface's own files are uncommitted at run time ({shown})")
                _fail(f"surface {spec['name']!r}: {shown} differ from HEAD, so a run now could not be "
                      f"attributed to any commit — the command would execute the working tree while "
                      f"the receipt named {head[:12]}. Commit the surface's code, then re-run")
            sys.stderr.write(f"idc-live-check: {spec['name']} — running `{spec['verify']}`\n")
            code, output, duration = run_verify(repo, spec, head)
            write_evidence(spec, code, output, head, duration)
            # Recorded AFTER the receipt, so a crash between the two leaves an uncorroborated receipt
            # (a gap, which re-running clears) rather than a witness vouching for a receipt that was
            # never written.
            record_witness(repo, spec, code, head)
            sys.stderr.write(f"idc-live-check: {spec['name']} — exit {code} in {duration}s; "
                             f"evidence regenerated at {spec['rel']}\n")

    gaps = []
    attested = []
    for spec in specs:
        reason, mode = audit_surface(repo, spec)
        if reason:
            gaps.append((spec["name"], reason))
        elif mode == MODE_ATTESTED:
            attested.append(spec["name"])

    if gaps:
        print("live: gap " + " ".join(name for name, _ in gaps))
        for name, reason in gaps:
            sys.stderr.write(f"idc-live-check: {name} — {reason}\n")
        sys.exit(1)
    # An attestation is a weaker claim than a measurement, and the verdict line says so out loud — a
    # clean line that hid it would let a hand-written note read exactly like a passing run.
    if attested:
        for name in attested:
            sys.stderr.write(f"idc-live-check: {name} — ATTESTED (hand-written), not executed\n")
        print("live: ok (attested)")
        sys.exit(0)
    print("live: ok")
    sys.exit(0)


if __name__ == "__main__":
    # Broken-pipe guard: `--run` streams a per-surface report whose length is the project's, not ours —
    # the unbounded-output half of the criterion in scripts/idc_stdio.py.
    import idc_stdio
    raise SystemExit(idc_stdio.run_guarded(main))
