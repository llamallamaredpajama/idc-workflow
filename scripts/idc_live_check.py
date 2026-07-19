#!/usr/bin/env python3
"""idc_live_check.py — the declared-live-surface evidence gate (`WORKFLOW.md §4.6`).

THE FAILURE THIS EXISTS FOR. Every IDC gate verifies CODE: the review dimensions, the architectural
fences, the per-issue verification surface, the acceptance check. All of them can be green while the
DEPLOYED product is broken, because the things that break a deployment most often are not in the
reviewed diff at all — a bucket that was never created, an env var that was never set, an IAM role
granted by hand. One governed repo shipped a phase with every PR merged and every gate green while
its running app could neither ingest nor open an item
(`docs/dev/2026-07-19-completion-honesty.md`). "All PRs merged + reviewed" was read as "the app
works," and the plan's own written finish line — drive the real signed-in app — was skipped.

WHAT IDC CAN HONESTLY ENFORCE. Not the deploy itself: IDC cannot know how to build, ship, or drive an
arbitrary product, and any attempt to hardcode that knowledge would be wrong for the next repo. What
it CAN enforce is a promise the project makes to itself. A repo DECLARES its live surfaces in
`WORKFLOW-config.yaml`; this gate then refuses to call a wave clean unless each declared surface
carries a dated, committed piece of evidence that someone actually drove it. IDC supplies the
obligation and the expiry, never the deploy knowledge.

NOT-DECLARED IS A FIRST-CLASS ANSWER (the no-burden rule). A repo with no `live_verification:` block —
or one that ships the template's `surfaces: []` — gets `live: not-declared` and exit 0, always. A
library, a CLI, a plugin like this one has no deployed surface to drive, and this gate must cost it
exactly nothing. Opting in is the ONLY way to be gated.

THE TEETH: EVIDENCE EXPIRES BY ITSELF. A one-time "I tested it" note that never goes stale is a
checkbox, and checkboxes get ticked. So each declared surface names the `paths:` whose code backs it,
and each evidence record names the `commit:` that was actually running when the journey was observed.
If ANY commit has landed on those paths since — a code change, a Terraform change, a deploy-script
change — the evidence is STALE and the surface is a gap again. That single rule is what covers
provisioning drift: a repo that lists `infra/` among a surface's paths cannot merge a Terraform change
and still claim the app was proven working, because the proof now predates the infrastructure it
describes. Evidence ages out on its own; nobody has to remember to invalidate it.

THE DECLARATION (`WORKFLOW-config.yaml`):

    live_verification:
      surfaces:
        - name: web
          journey: sign in -> ingest text -> open the item -> chat
          paths: [services/, web/, infra/]
          evidence: docs/workflow/live-verification/web.md

`name` and `paths` are required; `evidence` defaults to `docs/workflow/live-verification/<name>.md`;
`journey` is prose for the human who has to run it (this gate never interprets it, and never tries to
judge whether the journey was "really" performed — it verifies the obligation was met and is current,
which is all a deterministic check can honestly claim).

THE EVIDENCE RECORD. A markdown file — written by whoever drove the surface, reviewed like any other
committed artifact — carrying one machine-readable marker, modeled on the existing
`<!-- idc-deferral: {…} -->` / `<!-- idc-provenance: {…} -->` markers:

    <!-- idc-live-evidence: {"surface": "web", "commit": "<40-hex sha>", "observed": "..."} -->

`observed` is the free-text record of what was actually seen (the responses, the screens, the IDs) —
required and non-empty, because an evidence record with nothing observed in it is not evidence.

FAIL-CLOSED, with the house distinction between a FINDING and an INDETERMINATE (mirrors
`idc_acceptance_check.py` and `idc_gate_proof.py`). A surface with no evidence, stale evidence, or
evidence naming a commit that is not real / not merged is a GAP — a finding, exit 1. A CORRUPT marker,
a malformed declaration, or a repo git cannot be read in is an ERROR — exit 2. Collapsing the second
into "no gap" would let damaging an evidence file manufacture a clean bill of health.

Exit contract (the sibling-helper convention — see idc_acceptance_check.py):
  exit 0  `live: not-declared`        — no live surface declared; this repo is not gated here.
  exit 0  `live: ok`                  — every declared surface has current evidence.
  exit 1  `live: gap <name> …`        — those surfaces have missing or stale evidence.
  exit 2  `live: error <why>`         — the check could not be established (INDETERMINATE).

Usage: idc_live_check.py --repo <dir> [--config <WORKFLOW-config.yaml>]
"""
import argparse
import json
import os
import re
import subprocess
import sys

# The evidence marker. The sentinel is matched FIRST and the payload captured up to the comment close,
# so a CORRUPT payload fails closed (exit 2) rather than slipping past a `{…}`-anchored pattern as
# "no marker at all" (the same discipline as idc_acceptance_check.DEFERRAL_MARKER).
EVIDENCE_MARKER = re.compile(r"<!--\s*idc-live-evidence:\s*(.*?)\s*-->", re.S)
REQUIRED_EVIDENCE_KEYS = ("surface", "commit", "observed")

CONFIG_BASENAME = "WORKFLOW-config.yaml"
BLOCK_KEY = "live_verification"
DEFAULT_EVIDENCE_DIR = "docs/workflow/live-verification"

# A mapping-key line inside the block: indent, key, colon, value.
_KEY_LINE = re.compile(r"^(\s*)([A-Za-z_][\w.-]*):\s*(.*)$")
# A list-item line: indent, dash, then optionally the first `key: value` on the same line.
_ITEM_LINE = re.compile(r"^(\s*)-\s*(.*)$")
# `journey` is prose a human wrote and may legitimately contain `#`, so an inline-comment strip is
# only ever applied to the structural keys.
_STRUCTURAL_KEYS = ("name", "paths", "evidence")


def _fail(reason):
    """INDETERMINATE — print the machine-readable error line and exit 2 (never a hollow clean)."""
    print(f"live: error {reason}")
    sys.exit(2)


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


def _git(repo, *args):
    """(rc, stdout) for a git call in `repo`; a git that cannot be run at all is an ERROR."""
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        _fail(f"git could not be run in {repo} ({e})")
    return r.returncode, (r.stdout or "").strip()


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


def check_surface(repo, surface):
    """`(name, reason)` — `reason` is None when the surface's evidence is present and current."""
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
    rel = (surface.get("evidence") or os.path.join(DEFAULT_EVIDENCE_DIR, f"{name}.md")).strip()
    evidence_path = rel if os.path.isabs(rel) else os.path.join(repo, rel)

    payload, missing = read_evidence(evidence_path)
    if missing:
        return name, missing
    if payload["surface"].strip() != name:
        return name, (f"{rel} is evidence for surface {payload['surface'].strip()!r}, not {name!r}")

    commit = payload["commit"].strip()
    rc, _ = _git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}")
    if rc != 0:
        return name, f"evidence names commit {commit[:12]} which does not exist in this repo"
    # The evidence must describe something that actually SHIPPED. A commit that is not an ancestor of
    # HEAD is on an unmerged branch (or was rewritten away): a journey observed there proves nothing
    # about what is on the mainline now.
    rc, _ = _git(repo, "merge-base", "--is-ancestor", commit, "HEAD")
    if rc != 0:
        return name, (f"evidence names commit {commit[:12]}, which is not an ancestor of HEAD "
                      f"(unmerged or rewritten) — it does not describe what shipped")
    # THE EXPIRY. Anything landing on the surface's own paths since the evidence was taken invalidates
    # it, because the thing that was proven working is no longer the thing that is deployed.
    rc, out = _git(repo, "log", "--format=%H", f"{commit}..HEAD", "--", *paths)
    if rc != 0:
        _fail(f"git log over surface {name!r} paths failed")
    if out:
        n = len(out.splitlines())
        return name, (f"evidence is STALE — {n} commit(s) have landed on {', '.join(paths)} since "
                      f"{commit[:12]}; re-drive the journey and record fresh evidence")
    return name, None


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="idc_live_check.py",
        description="Require current, committed evidence that each DECLARED live surface was actually "
                    "driven. No declaration means no gate. Read-only; fail-closed.")
    ap.add_argument("--repo", default=".", help="the governed repo root (default: cwd)")
    ap.add_argument("--config", default=None,
                    help=f"path to {CONFIG_BASENAME} (default: <repo>/{CONFIG_BASENAME})")
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

    if not surfaces:
        print("live: not-declared")
        sys.exit(0)

    rc, _ = _git(repo, "rev-parse", "--git-dir")
    if rc != 0:
        _fail(f"{repo} is not a git repository — evidence freshness cannot be established")

    gaps = []
    try:
        for surface in surfaces:
            name, reason = check_surface(repo, surface)
            if reason:
                gaps.append((name, reason))
    except ValueError as e:
        _fail(str(e))

    if gaps:
        print("live: gap " + " ".join(name for name, _ in gaps))
        for name, reason in gaps:
            sys.stderr.write(f"idc-live-check: {name} — {reason}\n")
        sys.exit(1)
    print("live: ok")
    sys.exit(0)


if __name__ == "__main__":
    main()
