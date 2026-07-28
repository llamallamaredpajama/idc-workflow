#!/usr/bin/env python3
"""The ONE reader that answers "is this repo's pathway-security CLAIM honest for its backend?"

Spec §2.1 (`docs/specs/idc-convergent-pathway-integrity-spec.md`): `controlled` and `app-locked`
promise that supported runtime hooks deny local off-path mutations AND that a required deterministic
GitHub check plus repository rules block off-path *integration*. The filesystem tracker has no
integration boundary at all, so it "MUST NOT claim hard pathway security", and `/idc:doctor` MUST
FAIL a `controlled`/`app-locked` configuration that runs on it.

`/idc:init`'s scaffold door already refuses to CREATE that combination. A scaffold door only guards
creation time, though: a `WORKFLOW-config.yaml` hand-edited to `controlled` afterwards — or a repo
adopted from elsewhere — sails past it and then reads as fully governed. Doctor is the standing
diagnostic, so this is where the claim is re-checked on every run.

Three answers, and the third is the load-bearing one:

  * exit 0 — HONEST. The claim matches the backend (any github posture; filesystem declaring `off`).
  * exit 1 — DISHONEST. Backend `filesystem` while the config claims `controlled`/`app-locked`; OR a
             claiming mode on a host whose `python3` cannot run the runtime hooks (see below).
             A named one-line refusal goes to stderr.
  * exit 2 — INDETERMINATE. The claim could not be established: `WORKFLOW-config.yaml` missing or
             unreadable, the tracker backend missing/unreadable/unrecognized, or the shared runtime
             preflight could not be executed to judge the hook runtime.

WHY THE HOOK RUNTIME IS PART OF THE CLAIM (F57). Half of what `controlled`/`app-locked` promise is
LOCAL: "supported runtime hooks deny off-path mutations". Those hooks need Python 3.10 or newer —
`scripts/hooks/idc_interlock_gate.py` raises on import under 3.9 — and until F57 the transport
answered an unsupported interpreter with `exit 0`, i.e. it allowed every mutation and said nothing.
The transport now fails closed, but a repo whose interpreter cannot evaluate mutations is still not
delivering the posture it advertises: it refuses everything, authorized work included. Nothing else
in the tree looked at this (`idc_python_runtime.sh` was referenced only by the hook wrappers
themselves), so the repo could report itself fully wired while enforcing nothing. This door is where
that becomes visible.

WHY THE DOOR RE-CHECKS THE CONFIG ITSELF INSTEAD OF TRUSTING THE PARSER. The shipped Path Gate
parser `idc_path_gate.pathway_mode()` answers `"off"` when it cannot open the config at all
(`except OSError: return "off"`), which is exactly right for the RUNTIME gate — an unreadable config
must not be treated as enforcing — but it makes "explicitly non-enforcing" and "I could not read
your config" indistinguishable THROUGH THE PARSER. A doctor row that just asked the parser would
therefore report a repo with no config as the honest `off` posture: a clean bill of health derived
from a file nobody could read. So the readability of the two configs is established HERE, first, and
"cannot tell" is reported as its own answer. Indeterminate is never an honest PASS — and the fix is
never to teach the runtime parser this, because the runtime's fail-closed default is the correct one
for enforcement.

Deterministic: two small file reads plus — only for a claiming mode — one local run of the shipped
runtime preflight (`sh scripts/idc_python_runtime.sh`, the exact probe the hook wrappers use, so the
answer is about the `python3` the hooks resolve rather than the one that happens to be running this
script). No network, no `gh`, no LLM, no writes.

    python3 scripts/idc_doctor_pathway_check.py --repo <governed-repo-root>
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import idc_path_gate as PG  # noqa: E402 — sibling script, path set above

# The governed repo's two claim-bearing configs.
CONFIG_RELPATH = "WORKFLOW-config.yaml"
TRACKER_CONFIG_RELPATH = os.path.join("docs", "workflow", "tracker-config.yaml")

# The modes that make a HARD pathway-security claim (spec §2.1). `off` claims nothing, so it is
# honest on every backend.
CLAIMING_MODES = ("controlled", "app-locked")

# The backends IDC ships. An unrecognized value is INDETERMINATE, not honest: the door cannot judge
# a claim against a backend whose integration boundary it knows nothing about, and a silent PASS
# there would be a clean bill of health nobody established. A new backend lands with a deliberate
# edit here.
KNOWN_BACKENDS = ("github", "filesystem")
FILESYSTEM_BACKEND = "filesystem"

EXIT_HONEST = 0
EXIT_DISHONEST = 1
EXIT_INDETERMINATE = 2

# The verdict token an honest run prints. Deliberately absent from every other exit path so a
# surface that greps this output can never read "cannot tell" as "clean".
HONEST_TOKEN = "pathway-claim: honest"

# The shared runtime preflight every hook wrapper runs before spawning the gate. Asking IT — rather
# than this process's own `sys.version_info` — keeps the answer about the `python3` the HOOKS
# resolve from PATH, which is not necessarily the interpreter someone invoked doctor with.
RUNTIME_PREFLIGHT = os.path.join(SCRIPT_DIR, "idc_python_runtime.sh")


def hook_runtime_supported():
    """``(True|False|None, reason)`` — can the hooks' `python3` run the Path Gate?

    ``None`` means the question could not be asked (the preflight is missing or unrunnable), which
    is INDETERMINATE, never a pass: this door's whole rule is that "cannot tell" is never honest.
    """
    if not os.path.isfile(RUNTIME_PREFLIGHT):
        return None, f"the shared runtime preflight {os.path.basename(RUNTIME_PREFLIGHT)} is missing"
    try:
        proc = subprocess.run(["sh", RUNTIME_PREFLIGHT], capture_output=True)
    except OSError as exc:
        return None, (f"the shared runtime preflight could not be executed "
                      f"({exc.__class__.__name__})")
    return proc.returncode == 0, None


def _read_text(path):
    """``(text, None)`` or ``(None, reason)`` — a readable, decodable regular file, or why not.

    A directory in the file's place, a permissions denial and undecodable bytes are all "cannot
    read": the parser swallows the first two into `off` and would RAISE on the third, so all three
    are settled here instead.
    """
    if not os.path.isfile(path):
        return None, "missing"
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read(), None
    except OSError as exc:
        return None, f"unreadable ({exc.__class__.__name__})"
    except UnicodeDecodeError:
        return None, "unreadable (not valid UTF-8)"


def read_backend(text):
    """The `backend:` value out of a tracker-config.yaml body, or ``None`` when it declares none.

    The parse is the repo's established no-yq convention, mirroring `idc_recirc_sweep.read_backend`
    line for line so the two surfaces cannot drift into disagreeing about what a config says.
    """
    for line in text.splitlines():
        m = re.match(r"^\s*backend:\s*([A-Za-z0-9_-]+)", line)
        if m:
            return m.group(1).strip()
    return None


def classify(repo):
    """``(exit_code, message)`` for `repo` — the whole decision, importable and side-effect free."""
    root = os.path.realpath(os.path.abspath(repo))

    tracker_text, why = _read_text(os.path.join(root, TRACKER_CONFIG_RELPATH))
    if why:
        return EXIT_INDETERMINATE, (
            f"{TRACKER_CONFIG_RELPATH} is {why} — the tracker backend is unknown, so this repo's "
            f"pathway-security claim CANNOT BE ESTABLISHED (not the same as honest). Restore the "
            f"tracker contract (run `/idc:init`), then re-run `/idc:doctor`.")
    backend = read_backend(tracker_text)
    if backend is None:
        return EXIT_INDETERMINATE, (
            f"{TRACKER_CONFIG_RELPATH} declares no `backend:` — the pathway-security claim CANNOT "
            f"BE ESTABLISHED (not the same as honest). Repair the tracker contract (run "
            f"`/idc:init`), then re-run `/idc:doctor`.")
    if backend not in KNOWN_BACKENDS:
        return EXIT_INDETERMINATE, (
            f"{TRACKER_CONFIG_RELPATH} declares an unrecognized backend `{backend}` (known: "
            f"{', '.join(KNOWN_BACKENDS)}) — this door cannot judge a pathway claim against a "
            f"backend it knows nothing about, so the claim is INDETERMINATE, never honest.")

    # Establish the config's readability BEFORE the parser speaks: `pathway_mode()` answers "off"
    # for a config it could not open, which would read as an honest non-enforcing posture.
    config_path = os.path.join(root, CONFIG_RELPATH)
    _, why = _read_text(config_path)
    if why:
        return EXIT_INDETERMINATE, (
            f"{CONFIG_RELPATH} is {why} — the declared `pathway_enforcement.mode` CANNOT BE READ, "
            f"so this repo's pathway-security claim is INDETERMINATE. (The runtime Path Gate "
            f"parser reports an unreadable config as `off`, which is the correct FAIL-CLOSED "
            f"default for enforcement but is not evidence of an honest claim.) Restore "
            f"{CONFIG_RELPATH} (run `/idc:init`), then re-run `/idc:doctor`.")

    try:
        mode = PG.pathway_mode(root)
    except Exception as exc:  # noqa: BLE001 — a parser failure is "cannot tell", never "honest"
        return EXIT_INDETERMINATE, (
            f"the shipped Path Gate parser could not read {CONFIG_RELPATH} "
            f"({exc.__class__.__name__}) — the pathway-security claim is INDETERMINATE, never "
            f"honest. Repair {CONFIG_RELPATH}, then re-run `/idc:doctor`.")

    # A readable config that declares an UNRECOGNIZED `mode:` (a typo like `controllled`, or a blank
    # value) is malformed governed state, not the honest `off` posture. The parser maps it to
    # UNKNOWN_MODE; the runtime already fails closed on it, and doctor must report it as indeterminate
    # so a repo that TRIED to claim enforcement (and mistyped it) never reads as a clean bill of health.
    if mode == PG.UNKNOWN_MODE:
        return EXIT_INDETERMINATE, (
            f"{CONFIG_RELPATH} declares a `pathway_enforcement.mode` that is not one of "
            f"{', '.join(sorted(PG.PATHWAY_MODES))} — the pathway-security claim is INDETERMINATE, "
            f"never honest (the runtime fails closed on it). Set a recognized mode in "
            f"{CONFIG_RELPATH}, then re-run `/idc:doctor`.")

    if backend == FILESYSTEM_BACKEND and mode in CLAIMING_MODES:
        return EXIT_DISHONEST, (
            f"the `{FILESYSTEM_BACKEND}` tracker backend claims `pathway_enforcement.mode: {mode}` "
            f"— it has no integration boundary to enforce, so it MUST NOT claim hard pathway "
            f"security (spec §2.1). Set `mode: off` in {CONFIG_RELPATH}, or move this repo to the "
            f"`github` backend via `/idc:init`.")

    # The LOCAL half of a claiming mode is "supported runtime hooks deny off-path mutations". A
    # `python3` older than 3.10 cannot run the gate at all, so the hooks evaluate nothing (F57).
    if mode in CLAIMING_MODES:
        runtime_ok, why = hook_runtime_supported()
        if runtime_ok is None:
            return EXIT_INDETERMINATE, (
                f"{why} — whether this repo's `{mode}` runtime enforcement can actually run CANNOT "
                f"BE ESTABLISHED, so the pathway-security claim is INDETERMINATE, never honest. "
                f"Repair the plugin installation, then re-run `/idc:doctor`.")
        if not runtime_ok:
            return EXIT_DISHONEST, (
                f"this repo claims `pathway_enforcement.mode: {mode}`, but the `python3` the IDC "
                f"hooks resolve is missing or older than 3.10, so the PreToolUse Path Gate cannot "
                f"evaluate a single mutation — the transport refuses every one of them (including "
                f"authorized work) instead of enforcing the posture this mode advertises. Install "
                f"or select Python 3.10 or newer, then re-run `/idc:doctor`.")

    return EXIT_HONEST, f"{HONEST_TOKEN} (backend={backend}, pathway_enforcement.mode={mode})"


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Is this repo's pathway-security claim honest for its tracker backend? "
                    "(0 honest, 1 dishonest, 2 indeterminate — indeterminate is never honest.)")
    p.add_argument("--repo", default=".", help="the governed repo root (holds WORKFLOW-config.yaml)")
    args = p.parse_args(argv)

    code, message = classify(args.repo)
    if code == EXIT_HONEST:
        print(message)
    else:
        sys.stderr.write(f"idc-doctor-pathway: {message}\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
