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

THE TEETH: EVIDENCE EXPIRES BY ITSELF. Each declared surface names the `paths:` whose code backs it,
and each evidence record names the `commit:` that was checked out when the command ran. If ANY commit
has landed on those paths since — a code change, a Terraform change, a deploy-script change — the
evidence is STALE and the surface is a gap again. That single rule is what covers provisioning drift:
a repo that lists `infra/` among a surface's paths cannot merge a Terraform change and still claim the
app was proven working, because the proof now predates the infrastructure it describes. The recorded
`command` must also still MATCH the declared one, so weakening or swapping the check invalidates every
receipt it produced. Evidence ages out on its own; nobody has to remember to invalidate it.

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
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

# The evidence marker. The sentinel is matched FIRST and the payload captured up to the comment close,
# so a CORRUPT payload fails closed (exit 2) rather than slipping past a `{…}`-anchored pattern as
# "no marker at all" (the same discipline as idc_acceptance_check.DEFERRAL_MARKER).
EVIDENCE_MARKER = re.compile(r"<!--\s*idc-live-evidence:\s*(.*?)\s*-->", re.S)
# Present in EVERY record, whatever produced it. `mode` is deliberately NOT here: a record with no
# `mode` is a legacy/hand-written note, which is an honest "never executed" GAP, not a corrupt file.
REQUIRED_EVIDENCE_KEYS = ("surface", "commit", "observed")

MODE_EXECUTED = "executed"
MODE_ATTESTED = "attested"

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
# EVERY QUANTIFIER IS BOUNDED, and the input is TRUNCATED BEFORE these ever run (see run_verify). Both
# are load-bearing, not tidiness: the first draft had an unbounded `[\w.-]*` around the named-secret
# rule and redacted the whole capture, and a verify script that printed 400 KB on one line wedged the
# gate for minutes with no timeout left to save it (the command had already exited). A check that hangs
# is a check that gets removed. `tests/smoke/phase4-completion-honesty.sh` G5 is that regression.
_REDACTORS = (
    (re.compile(r"-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----", re.S),
     "[REDACTED PRIVATE KEY]"),
    # `scheme://user:pass@host` — credentials smuggled in a URL.
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]{0,32}://)[^/\s:@]{1,256}:[^/\s@]{1,256}@"), r"\1[REDACTED]@"),
    # `Authorization: Bearer …`, `Basic …`, `token …`.
    (re.compile(r"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,4096}"), r"\1 [REDACTED]"),
    # Anything that NAMES itself a secret: key/token/secret/password/credential/auth = or : value.
    (re.compile(r"(?i)([\w.-]{0,32}(?:secret|password|passwd|token|api[_-]?key|apikey|credential|"
                r"auth(?:orization)?)[\w.-]{0,32})\s*[:=]\s*(\"[^\"]{0,512}\"|'[^']{0,512}'|\S{1,512})"),
     r"\1=[REDACTED]"),
    # Known credential shapes, even bare in a log line.
    (re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
                r"AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|ya29\.[0-9A-Za-z_-]{10,}|"
                r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,})"), "[REDACTED]"),
    # The backstop: any long opaque run is treated as a credential we do not have a name for.
    (re.compile(r"\b[A-Za-z0-9_\-]{40,4096}\b"), "[REDACTED]"),
)


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


def _tail(text, limit):
    """The LAST `limit` characters — a failing command's reason is at the end, not the beginning."""
    text = text or ""
    if len(text) <= limit:
        return text
    return "…[truncated]…\n" + text[-limit:]


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
        # The command is stored REDACTED, because it is what lands in the record and what the audit
        # compares against. A config that inlines a token still never writes it to disk.
        "verify": redact(verify),
        "timeout": timeout,
        "rel": rel,
        "evidence_path": rel if os.path.isabs(rel) else os.path.join(repo, rel),
    }


def _git(repo, *args):
    """(rc, stdout) for a git call in `repo`; a git that cannot be run at all is an ERROR."""
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        _fail(f"git could not be run in {repo} ({e})")
    return r.returncode, (r.stdout or "").strip()


def run_verify(repo, spec):
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
    """
    started = time.time()
    try:
        proc = subprocess.Popen(spec["verify"], shell=True, cwd=repo, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                errors="replace", start_new_session=True)
    except (OSError, ValueError) as e:
        _fail(f"surface {spec['name']!r}: the verify command could not be started ({e})")
    try:
        out, _ = proc.communicate(timeout=spec["timeout"])
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        _fail(f"surface {spec['name']!r}: the verify command did not finish within "
              f"{spec['timeout']}s — a hung probe proves nothing (raise `timeout:` or make the check "
              f"terminate)")
    except (OSError, subprocess.SubprocessError) as e:  # pragma: no cover — defensive
        _kill_group(proc)
        _fail(f"surface {spec['name']!r}: the verify command could not be run ({e})")
    duration = round(time.time() - started, 1)
    # TRUNCATE FIRST, THEN REDACT. Only the bounded tail is ever kept, so redaction runs over a few KB
    # instead of whatever the script decided to print — and nothing un-redacted is written or printed
    # anywhere in between. (The full capture lives only in this local, and dies with the call.)
    output = redact(_tail(out or "", MAX_BODY_CHARS))
    if rc in (126, 127):
        _fail(f"surface {spec['name']!r}: the verify command could not be executed (shell exit {rc} — "
              f"not found or not executable). A missing check is INDETERMINATE, never a pass")
    return rc, redact(out or ""), duration


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


def write_evidence(spec, rc, output, commit, duration):
    """Regenerate the surface's evidence record from a REAL run. Written on failure too, deliberately.

    Writing only on success would leave yesterday's PASSING receipt in place after today's run failed —
    the audit would keep reporting `live: ok` while the command that just ran said otherwise. The
    record always describes the LAST execution, so the fast audit and a fresh `--run` can never
    disagree.
    """
    body = _tail(output.strip(), MAX_BODY_CHARS)
    observed = " ".join(_tail(output.strip(), MAX_OBSERVED_CHARS).split()) or f"(no output; exit {rc})"
    payload = {
        "surface": spec["name"],
        "mode": MODE_EXECUTED,
        "command": spec["verify"],
        "exit_code": rc,
        "commit": commit,
        "ran_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_s": duration,
        "observed": observed,
    }
    doc = (
        f"# Live verification — {spec['name']}\n\n"
        "GENERATED by `idc_live_check.py --run`. Do not hand-edit: the next run overwrites this file, "
        "and a hand-written claim does not satisfy the gate.\n\n"
        f"- **surface:** {spec['name']}\n"
        f"- **command:** `{spec['verify']}`\n"
        f"- **exit code:** {rc} ({'PASS' if rc == 0 else 'FAIL'})\n"
        f"- **commit:** `{commit}`\n"
        f"- **ran at:** {payload['ran_at']}\n"
        f"- **duration:** {duration}s\n\n"
        "## Output (bounded; credentials redacted)\n\n"
        "```\n" + (body if body else "(no output)") + "\n```\n\n"
        f"<!-- idc-live-evidence: {json.dumps(payload, sort_keys=True)} -->\n"
    )
    try:
        parent = os.path.dirname(spec["evidence_path"])
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(spec["evidence_path"], "w", encoding="utf-8") as fh:
            fh.write(doc)
    except OSError as e:
        _fail(f"surface {spec['name']!r}: could not write the evidence record "
              f"{spec['rel']} ({e})")


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
    m = EVIDENCE_MARKER.search(text)
    if not m:
        return None, f"{path} carries no idc-live-evidence marker"
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
        if exit_code != 0:
            return (f"the verify command FAILED (exit {exit_code}) on the last run — this is a finding "
                    f"about the product; read {spec['rel']} for the captured output, fix it, and "
                    f"re-run"), None

    commit = payload["commit"].strip()
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
    rc, out = _git(repo, "log", "--format=%H", f"{commit}..HEAD", "--", *spec["paths"])
    if rc != 0:
        _fail(f"git log over surface {spec['name']!r} paths failed")
    if out:
        n = len(out.splitlines())
        cure = ("re-attest it" if spec["attested"] else "re-run `idc_live_check.py --repo . --run`")
        return (f"evidence is STALE — {n} commit(s) have landed on {', '.join(spec['paths'])} since "
                f"{commit[:12]}; {cure}"), None
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
            sys.stderr.write(f"idc-live-check: {spec['name']} — running `{spec['verify']}`\n")
            code, output, duration = run_verify(repo, spec)
            write_evidence(spec, code, output, head, duration)
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
    main()
