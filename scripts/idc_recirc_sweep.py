#!/usr/bin/env python3
"""idc_recirc_sweep.py — the deterministic recirculation-intake safety net (`WORKFLOW.md §3/§4`).

Plan is the one gate that mints a Buildable issue: it writes a pillar `id` into the phase matrix
AND stamps the SAME id onto the issue as `<!-- idc-provenance: {"matrix":"…","pillar":"…"} -->`,
so a planned Buildable is provably linked to a matrix pillar *by construction*. An issue that
bypassed Plan — a raw `gh issue create … Stage=Buildable`, or a captured review-residual — carries
no such provenance, yet Build/Autorun consume the Buildable lane on trust and would claim it cold.

This helper is the detective that re-reads the Buildable lane and corrects that leak. Per
`Stage=Buildable` + `Status=Todo` issue, in priority order:

  1. valid `idc-provenance` (its `pillar` is in the NAMED matrix YAML's id set) → planned → LEAVE.
  2. carries an `idc-discovery`/`idc-deferral` marker (and no valid provenance) → unambiguous rogue
     → re-stage to `Recirculation` + clear `Wave` (the discovered scope is captured as a ticket).
  3. no provenance AND no marker → AMBIGUOUS → auto re-stage ONLY when the provenance regime is
     active on this board (≥1 Buildable carries a valid provenance marker, proving new-Plan has run
     here); otherwise SURFACE in `--report` only — never silently mutate a legacy board.
  4. no `*.yaml` under `docs/workflow/pillar-matrices/` → SKIP the provenance check entirely (a
     legacy board with no matrix regime is left untouched — mirrors doctor Row 9's filesystem skip).

It also captures untickered `idc-discovery`/`idc-deferral` markers into Recirculation tickets (the
C2 five-field body), idempotently (dedupe key = origin issue + marker `what`).

Two modes:
  * `--auto-correct` — the SessionEnd hook. Mutates the board through the active backend; fail-soft
    (never raises, always exits 0) so it can never block session exit.
  * `--report`       — `/idc:doctor` Row 9 + autorun preflight. Read-only, mutates nothing, prints
    findings, exits 0 (2 only on an unreadable tracker, so doctor can SKIP).

Backend split (the leak is a github board; the filesystem backend stores fields, not issue bodies):
  * github     — full sweep: provenance + marker scan, re-stage + Wave-clear, ticket-filing, via `gh`.
  * filesystem — markers ride issue *comments* (as the deferral gate already reads them), so a
    discovery/deferral-marked rogue is re-staged in place + Wave cleared; the body-provenance regime
    (Plan stamps github bodies) and the C2-body ticket-filing are github-only, so on filesystem the
    regime is never active (bare Buildables are never auto-restaged) and no separate ticket is filed.

Stdlib only (like its sibling helpers); reuses `idc_matrix_check.parse_matrix` for the matrix id set
and `idc_tracker_fs` for the filesystem write.

Usage:
  idc_recirc_sweep.py --repo <dir> --auto-correct [--tracker <TRACKER.md>] [--matrices <dir>]
  idc_recirc_sweep.py --repo <dir> --report       [--tracker <TRACKER.md>] [--matrices <dir>]
"""
import argparse
import json
import os
import re
import subprocess
import sys

# Reuse the sibling helpers (same directory) rather than re-implement matrix parsing / fs writes.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_matrix_check  # noqa: E402  — parse_matrix (constrained-YAML pillar scanner)
import idc_tracker_fs    # noqa: E402  — load/save/find + atomic TRACKER.md writer
import idc_gh_board      # noqa: E402  — shared paginating board reader (TRUE cursor pagination)

# ── markers ──────────────────────────────────────────────────────────────────
# Plan stamps provenance; the finisher posts discovery/deferral. The sentinel is matched first and
# the payload captured up to the comment close (re.S), so a corrupt payload is skipped, not slipped
# past a `{…}`-anchored pattern (mirrors idc_acceptance_check.DEFERRAL_MARKER).
PROVENANCE_MARKER = re.compile(r"<!--\s*idc-provenance:\s*(.*?)\s*-->", re.S)
DISCOVERY_MARKER = re.compile(r"<!--\s*idc-discovery:\s*(.*?)\s*-->", re.S)
DEFERRAL_MARKER = re.compile(r"<!--\s*idc-deferral:\s*(.*?)\s*-->", re.S)
# A filed Recirculation ticket carries this hidden source marker so a re-run never files a duplicate
# (the stateless idempotency key — origin issue + marker `what`).
RECIRC_SOURCE_MARKER = re.compile(r"<!--\s*idc-recirc-source:\s*(.*?)\s*-->", re.S)

# ── decision actions ─────────────────────────────────────────────────────────
LEAVE = "leave"                  # valid provenance — planned, untouched
RESTAGE = "restage"              # rogue — re-stage to Recirculation + clear Wave
SURFACE = "surface"             # ambiguous, regime inactive — report only, never mutate
SKIP_NO_MATRIX = "skip-no-matrix"  # no matrix yaml — provenance regime not established

RECIRC_STAGE = "Recirculation"
BUILDABLE_STAGE = "Buildable"
TODO_STATUS = "Todo"


# ── pure marker / decision logic (unit-testable without any IO) ───────────────
def parse_markers(text, pattern):
    """Parsed JSON objects for each marker of `pattern` in `text`; unparseable markers are skipped.

    Fail-SOFT (skip), not fail-closed: this is an advisory safety net that must never crash a
    SessionEnd hook nor a read-only doctor row over one malformed hand-edited comment."""
    out = []
    for m in pattern.finditer(text or ""):
        try:
            obj = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def provenance_of(text):
    """The first well-shaped `idc-provenance` object (carries both `matrix` and `pillar`), or None."""
    for obj in parse_markers(text, PROVENANCE_MARKER):
        if obj.get("matrix") and obj.get("pillar"):
            return {"matrix": str(obj["matrix"]), "pillar": str(obj["pillar"])}
    return None


def provenance_is_valid(prov, matrices):
    """True iff `prov` names a matrix whose id set contains `prov['pillar']`.

    `matrices` is {matrix-basename: set(ids)} or None (no matrix yaml present). The check is
    STRICT to the *named* matrix (the link Plan wrote by construction), never a union — a pillar id
    that only exists in some other matrix does not validate."""
    if not prov or matrices is None:
        return False
    return prov.get("pillar") in matrices.get(prov.get("matrix"), set())


def decide(issue, matrices, regime_active):
    """PURE per-issue decision for a `Stage=Buildable`, `Status=Todo` issue.

    issue: {"number", "provenance": {"matrix","pillar"} | None, "has_discovery": bool}
      where `has_discovery` is True iff the issue carries an idc-discovery OR idc-deferral marker.
    matrices: {basename: set(ids)} or None (None ⇒ no matrix yaml ⇒ skip the provenance check).
    regime_active: True iff ≥1 scanned issue carries a VALID idc-provenance marker.

    Returns LEAVE / RESTAGE / SURFACE / SKIP_NO_MATRIX. Priority order is load-bearing: the no-matrix
    skip gates everything (legacy boards untouched); valid provenance wins over any marker; a marker
    on an unprovenanced issue is an unambiguous rogue; an unmarked unprovenanced issue is only a rogue
    once the provenance regime is active, else it is merely surfaced."""
    if matrices is None:
        return SKIP_NO_MATRIX
    if provenance_is_valid(issue.get("provenance"), matrices):
        return LEAVE
    if issue.get("has_discovery"):
        return RESTAGE
    if regime_active:
        return RESTAGE
    return SURFACE


def discovery_source(marker, host_number):
    """Normalize a discovery/deferral marker to its dedupe identity {origin, what}.

    A discovery marker names its own `origin` (`"#42|role"`); a deferral marker is anchored to the
    host issue it was posted on. `what` is the discovered/deferred scope phrase. Both are stringified
    so the (origin, what) key is hashable and stable across runs."""
    origin = marker.get("origin") or f"#{host_number}"
    return {"origin": str(origin), "what": str(marker.get("what", "")).strip()}


def recirc_ticket_body(src, area, suggested_scope):
    """The C2 five-field Recirculation body (idc_schema_check.check_recirculation requires all five
    non-empty) plus the hidden source marker that makes re-filing idempotent."""
    what = src["what"] or "unspecified scope discovered mid-build"
    marker = json.dumps({"origin": src["origin"], "what": src["what"]}, ensure_ascii=False)
    return (
        f"Stage: {RECIRC_STAGE}\n"
        f"Discovered: {what}\n"
        f"Area: {area or 'unknown'}\n"
        f"Suggested-scope: {suggested_scope or what}\n"
        f"Provenance: captured by idc-recirc-sweep from {src['origin']}\n"
        f"PRD-TRD-impact: unknown\n\n"
        f"<!-- idc-recirc-source: {marker} -->\n"
    )


# ── matrix id-set + backend resolution ───────────────────────────────────────
def load_matrices(matrices_dir):
    """{basename: set(pillar ids)} for every *.yaml/*.yml under `matrices_dir`, or None when the dir
    is absent or carries no yaml file (⇒ provenance regime not established ⇒ decide() returns skip)."""
    if not matrices_dir or not os.path.isdir(matrices_dir):
        return None
    files = [f for f in sorted(os.listdir(matrices_dir)) if f.endswith((".yaml", ".yml"))]
    if not files:
        return None
    out = {}
    for fn in files:
        try:
            with open(os.path.join(matrices_dir, fn), encoding="utf-8") as fh:
                pillars = idc_matrix_check.parse_matrix(fh.read())
            out[fn] = {p["id"] for p in pillars if p.get("id")}
        except OSError:
            out[fn] = set()
    return out


def read_backend(repo):
    """The `backend:` value from <repo>/docs/workflow/tracker-config.yaml, or None if absent."""
    cfg = os.path.join(repo, "docs", "workflow", "tracker-config.yaml")
    if not os.path.isfile(cfg):
        return None
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*backend:\s*([A-Za-z0-9_-]+)", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        return None
    return None


def read_config(repo):
    """project_number (str) + field_ids ({name: node-id}) from tracker-config.yaml (grep/sed parse,
    the repo's no-yq convention)."""
    cfg = os.path.join(repo, "docs", "workflow", "tracker-config.yaml")
    project_number, field_ids, in_fields = "", {}, False
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                # Strip an inline `# comment` (the template ships `project_number: 10  # …`) — the
                # `#`-exclusion mirrors the field_ids parse below; without it `gh` gets "10  # …"
                # and rejects it as an invalid number, silently disabling the whole github sweep.
                m = re.match(r'^project_number:\s*"?([^"#\n]*)"?', line)
                if m:
                    project_number = m.group(1).strip()
                if re.match(r"^field_ids:\s*$", line):
                    in_fields = True
                    continue
                if in_fields:
                    fm = re.match(r"^\s+([A-Za-z]+):\s*\"?([^\"#\n]*)\"?", line)
                    if fm:
                        field_ids[fm.group(1)] = fm.group(2).strip()
                    elif re.match(r"^\S", line):
                        in_fields = False
    except OSError:
        pass
    return project_number, field_ids


# ── findings model ───────────────────────────────────────────────────────────
class Finding:
    """One per-issue decision + the captures discovered on it, for both report + apply."""

    def __init__(self, number, action, reason, wave="", item_id=None):
        self.number = number
        self.action = action
        self.reason = reason
        self.wave = wave
        self.item_id = item_id          # github project item node id (None on filesystem)
        self.captures = []              # list of discovery_source dicts to file as tickets


# ── filesystem backend ───────────────────────────────────────────────────────
def scan_filesystem(tracker_path, matrices):
    """Build (findings, state). On filesystem, markers ride issue comments (no body); provenance
    markers are absent in practice (Plan stamps github bodies) so the regime stays inactive."""
    state = idc_tracker_fs.load(tracker_path)
    issues = state.get("issues", [])
    scanned = []
    for it in issues:
        if not isinstance(it, dict):
            continue
        if it.get("status") != TODO_STATUS:
            continue
        if (it.get("stage") or BUILDABLE_STAGE) != BUILDABLE_STAGE:
            continue
        text = "\n".join(str(c) for c in it.get("comments", []) if c is not None)
        disc = parse_markers(text, DISCOVERY_MARKER)
        defr = parse_markers(text, DEFERRAL_MARKER)
        scanned.append({
            "number": it.get("number"),
            "wave": it.get("wave") or "",
            "provenance": provenance_of(text),
            "discoveries": disc,
            "deferrals": defr,
        })
    regime_active = any(provenance_is_valid(s["provenance"], matrices) for s in scanned)
    findings = [build_finding(s, matrices, regime_active) for s in scanned]
    return findings, state


def apply_filesystem(findings, state, tracker_path):
    """Mutate TRACKER.md: re-stage each rogue to Recirculation + clear its Wave. Idempotent — an
    issue already at Recirculation with empty Wave is a no-op, so a re-run changes nothing."""
    changed = 0
    for f in findings:
        if f.action != RESTAGE:
            continue
        it = idc_tracker_fs.find(state, f.number)
        if it.get("stage") == RECIRC_STAGE and not it.get("wave"):
            continue  # already corrected — idempotent
        it["stage"] = RECIRC_STAGE
        it["wave"] = ""
        changed += 1
    if changed:
        idc_tracker_fs.save(tracker_path, state)
    return changed


# ── github backend (via gh subprocess; stdlib only) ──────────────────────────
def gh(args, repo):
    """Run `gh <args>` in `repo`. Returns (ok, stdout, stderr); ok=False on missing gh or non-zero."""
    try:
        p = subprocess.run(["gh"] + args, cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError) as e:
        return False, "", str(e)
    return (p.returncode == 0), p.stdout, p.stderr


def gh_owner(repo):
    ok, out, _ = gh(["repo", "view", "--json", "owner", "-q", ".owner.login"], repo)
    return out.strip() if ok else ""


def scan_github(repo, matrices, project_number, log):
    """Build (findings, ctx) for the github backend. Reads the WHOLE board once (paginated — gh's own
    item-list truncates at 30 items, blinding a grown board's Buildable lane), then each issue's
    body+comments. Fail-soft: any board-read failure logs + yields an empty sweep."""
    owner = gh_owner(repo)
    if not owner or not project_number:
        log("github: could not resolve owner/project_number — skipping sweep")
        return [], None
    try:
        items = idc_gh_board.fetch_items(owner, project_number, repo)
    except idc_gh_board.BoardReadError as e:
        log(f"github: board read failed — skipping sweep ({str(e)[:120]})")
        return [], None

    # Resolve the project node id once (needed by every item-edit --project-id).
    okn, node_out, _ = gh(["project", "view", project_number, "--owner", owner,
                           "--format", "json", "--jq", ".id"], repo)
    project_node = node_out.strip() if okn else ""
    ctx = {"owner": owner, "project_node": project_node, "project_number": project_number}

    scanned = []
    for it in items:
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:               # a draft item carries no issue number
            continue
        if (it.get("stage") or BUILDABLE_STAGE) != BUILDABLE_STAGE:
            continue
        okb, body_out, _ = gh(["issue", "view", str(number), "--json", "body,comments"], repo)
        text = ""
        if okb:
            try:
                jd = json.loads(body_out)
                text = (jd.get("body") or "") + "\n" + \
                    "\n".join(str((c or {}).get("body", "")) for c in jd.get("comments", []))
            except json.JSONDecodeError:
                text = ""
        scanned.append({
            "number": number,
            "status": it.get("status"),
            "wave": it.get("wave") or "",
            "item_id": it.get("id"),
            "provenance": provenance_of(text),
            "discoveries": parse_markers(text, DISCOVERY_MARKER),
            "deferrals": parse_markers(text, DEFERRAL_MARKER),
        })

    regime_active = any(provenance_is_valid(s["provenance"], matrices) for s in scanned)
    findings = []
    for s in scanned:
        # Re-stage decisions act only on the build-eligible lane (Status=Todo); marker capture below
        # runs over the whole Buildable lane (a finisher's discovery rides a now-Done issue).
        if s["status"] == TODO_STATUS:
            f = build_finding(s, matrices, regime_active)
        else:
            f = Finding(s["number"], LEAVE, "not in the Todo build-eligible lane",
                        wave=s["wave"], item_id=s["item_id"])
            attach_captures(f, s)
        f.item_id = s["item_id"]
        findings.append(f)
    return findings, ctx


def github_existing_sources(repo, ctx, log):
    """The {(origin, what)} already covered by an existing Recirculation ticket's hidden source
    marker — the stateless dedupe set that makes ticket-filing idempotent across runs. Reads the
    WHOLE board (paginated) so a Recirculation ticket past the first 30 items is not missed (which
    would re-file a duplicate).

    Returns the dedupe set, or None when the board read FAILS — a VISIBLE degraded state (logged) that
    the caller treats as "cannot dedupe → do not file". Returning an empty set here instead would
    SILENTLY risk re-filing a duplicate Recirculation ticket (the dedupe can't see the existing one),
    so fail-closed against duplicates rather than file blind."""
    seen = set()
    try:
        items = idc_gh_board.fetch_items(ctx["owner"], ctx["project_number"], repo)
    except idc_gh_board.BoardReadError as e:
        log(f"github: existing-ticket dedupe read FAILED ({str(e)[:120]}) — skipping ticket-filing "
            "this sweep to avoid duplicates (will retry next run)")
        return None
    for it in items:
        if (it.get("stage") or "") != RECIRC_STAGE:
            continue
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:
            continue
        okb, body_out, _ = gh(["issue", "view", str(number), "--json", "body"], repo)
        if not okb:
            continue
        try:
            body = json.loads(body_out).get("body") or ""
        except json.JSONDecodeError:
            continue
        for obj in parse_markers(body, RECIRC_SOURCE_MARKER):
            seen.add((str(obj.get("origin", "")), str(obj.get("what", "")).strip()))
    return seen


def apply_github(findings, repo, ctx, log):
    """Re-stage rogues (+ clear Wave) and file untickered-marker Recirculation tickets, all via gh.
    Fail-soft per issue — one gh error logs and continues, never aborting the sweep."""
    if ctx is None:
        return 0
    owner, project_node, project_number = ctx["owner"], ctx["project_node"], ctx["project_number"]
    # Resolve the Stage field id + Recirculation option id once.
    _, field_ids = read_config(repo)
    stage_fid, wave_fid = field_ids.get("Stage", ""), field_ids.get("Wave", "")
    ok, recirc_oid, _ = gh(["project", "field-list", project_number, "--owner", owner,
                            "--format", "json", "--jq",
                            f'.fields[]|select(.name=="Stage")|.options[]'
                            f'|select(.name=="{RECIRC_STAGE}")|.id'], repo)
    recirc_oid = recirc_oid.strip() if ok else ""
    changed = 0

    def stage_recirc(item_id):
        """Set one board item's Stage → Recirculation (shared by the re-stage loop + ticket-filing).
        Returns gh()'s (ok, stdout, stderr)."""
        return gh(["project", "item-edit", "--id", item_id, "--project-id", project_node,
                   "--field-id", stage_fid, "--single-select-option-id", recirc_oid], repo)

    for f in findings:
        if f.action != RESTAGE or not f.item_id:
            continue
        if not (project_node and stage_fid and recirc_oid):
            log(f"github: #{f.number} re-stage skipped — Stage field/option id unresolved "
                "(provision the Recirculation option via /idc:init)")
            continue
        ok1, _, err1 = stage_recirc(f.item_id)
        if not ok1:
            log(f"github: #{f.number} re-stage failed ({err1.strip()[:120]})")
            continue
        # The re-stage succeeded (the rogue is out of the Buildable lane — the load-bearing
        # correction, so it counts as a board change). The Wave clear is best-effort residue cleanup;
        # CHECK its return so a FAILED clear is surfaced, never silently reported as "Wave cleared"
        # (the same success-only honesty as the ticket-filing path below).
        if f.wave and wave_fid:          # clear Wave (only if it carries one)
            okw, _, errw = gh(["project", "item-edit", "--id", f.item_id, "--project-id", project_node,
                               "--field-id", wave_fid, "--clear"], repo)
            tail = "+ Wave cleared" if okw else \
                f"but Wave clear FAILED ({errw.strip()[:120]}) — stale Wave remains"
        else:
            tail = "(no Wave to clear)"
        log(f"github: #{f.number} re-staged → {RECIRC_STAGE} {tail} ({f.reason})")
        changed += 1

    # Ticket capture (idempotent): file one Recirculation ticket per untickered (origin, what).
    captures = [c for f in findings for c in f.captures]
    if captures:
        already = github_existing_sources(repo, ctx, log)
        if already is None:
            # The dedupe board read failed (logged above) — do NOT file blind (would risk duplicates).
            return changed
        for c in captures:
            key = (c["origin"], c["what"])
            if key in already:
                continue
            already.add(key)             # in-run dedupe too (two markers, same scope)
            body = recirc_ticket_body(c, c.get("area", ""), c.get("suggested_scope", ""))
            title = f"recirc: {c['what'][:60] or 'discovered scope'}"
            okc, url_out, errc = gh(["issue", "create", "--title", title, "--body", body], repo)
            if not okc:
                log(f"github: ticket for {c['origin']} failed ({errc.strip()[:120]})")
                continue
            url = url_out.strip().splitlines()[-1] if url_out.strip() else ""
            # The issue now EXISTS, so an item-add / item-edit failure is a PARTIAL: surface it and do
            # NOT report it as a clean "filed" (the old path logged "filed" + counted it even when the
            # add/edit failed, hiding an off-board or un-staged orphan). Capture the new item's node id
            # straight from item-add (`--jq .id`) — no board re-read.
            ok_add, iid_out, _ = gh(["project", "item-add", project_number, "--owner", owner,
                                     "--url", url, "--format", "json", "--jq", ".id"], repo)
            iid = iid_out.strip() if ok_add else ""
            if not iid:
                log(f"github: ticket {url or c['origin']} created but NOT added to the board "
                    "(item-add failed) — surfaced, not counted as filed")
                continue
            if not (project_node and stage_fid and recirc_oid):
                log(f"github: ticket {url} added but NOT staged {RECIRC_STAGE} "
                    "(Stage field/option id unresolved — provision via /idc:init) — not counted as filed")
                continue
            ok_edit, _, erre = stage_recirc(iid)
            if not ok_edit:
                log(f"github: ticket {url} added but Stage→{RECIRC_STAGE} FAILED "
                    f"({erre.strip()[:120]}) — surfaced, not counted as filed")
                continue
            log(f"github: filed Recirculation ticket for {c['origin']} ({c['what'][:60]})")
            changed += 1
    return changed


# ── shared finding builder ───────────────────────────────────────────────────
def attach_captures(finding, scanned):
    """Attach the issue's discovery/deferral markers as ticket captures. A deferral already routed to
    a tracker issue (`suggested_issue: #N`) is considered tickered and is NOT re-captured."""
    for d in scanned["discoveries"]:
        finding.captures.append({**discovery_source(d, scanned["number"]),
                                 "area": str(d.get("area", "")),
                                 "suggested_scope": str(d.get("suggested_scope", ""))})
    for d in scanned["deferrals"]:
        if str(d.get("suggested_issue", "")).strip():
            continue  # already routed to a ticket — not untickered
        finding.captures.append({**discovery_source(d, scanned["number"]),
                                 "area": "", "suggested_scope": ""})


def build_finding(scanned, matrices, regime_active):
    """Run decide() on a scanned issue + attach its marker captures."""
    has_discovery = bool(scanned["discoveries"] or scanned["deferrals"])
    action = decide({"number": scanned["number"], "provenance": scanned["provenance"],
                     "has_discovery": has_discovery}, matrices, regime_active)
    reason = {
        LEAVE: "valid provenance — planned",
        RESTAGE: ("carries a discovery/deferral marker, no valid provenance — rogue"
                  if has_discovery else "no provenance, regime active — rogue"),
        SURFACE: "no provenance, regime inactive — ambiguous (not mutated)",
        SKIP_NO_MATRIX: "no pillar matrix — provenance regime not established",
    }[action]
    f = Finding(scanned["number"], action, reason, wave=scanned["wave"])
    attach_captures(f, scanned)
    return f


# ── report rendering ─────────────────────────────────────────────────────────
def render_report(findings, backend, matrices):
    lines = []
    if matrices is None:
        lines.append("recirc-sweep: skipped — no pillar matrix (provenance regime not established)")
        return lines
    rogue = [f for f in findings if f.action == RESTAGE]
    ambiguous = [f for f in findings if f.action == SURFACE]
    captures = [c for f in findings for c in f.captures]
    for f in rogue:
        lines.append(f"#{f.number}: rogue → re-stage to {RECIRC_STAGE} + clear Wave ({f.reason})")
    for f in ambiguous:
        lines.append(f"#{f.number}: ambiguous — surfaced only, not mutated ({f.reason})")
    for c in captures:
        lines.append(f"capture: untickered marker from {c['origin']} — file Recirculation ticket "
                     f"(\"{c['what'][:60]}\")")
    scanned = len(findings)
    if not rogue and not ambiguous and not captures:
        lines.append(f"recirc-sweep: clean ({scanned} buildable scanned)")
    else:
        note = "" if backend != "filesystem" else " — filesystem: ticket-capture is github-only"
        lines.append(f"recirc-sweep: {len(rogue)} rogue, {len(ambiguous)} ambiguous, "
                     f"{len(captures)} untickered marker(s) of {scanned} buildable scanned{note}")
    return lines


# ── entry point ──────────────────────────────────────────────────────────────
def run(repo, mode, tracker, matrices_dir):
    """Returns (exit_code, output_lines). Never raises in --auto-correct (fail-soft)."""
    out = []

    def log(msg):
        out.append(msg)

    matrices = load_matrices(matrices_dir)
    backend = read_backend(repo)
    if backend is None:
        # Not an IDC-governed repo (the hook wrapper already guards this; double-guard here).
        return 0, out

    if backend == "filesystem":
        if not os.path.isfile(tracker):
            if mode == "report":
                out.append("recirc-sweep: SKIP — filesystem backend has no TRACKER.md")
                return 0, out
            return 0, out
        try:
            findings, state = scan_filesystem(tracker, matrices)
        except SystemExit:
            # idc_tracker_fs.load die()s (exits) on a corrupt tracker; convert to a soft skip.
            return (2 if mode == "report" else 0), out
        if mode == "auto-correct":
            n = apply_filesystem(findings, state, tracker)
            if n:
                log(f"filesystem: re-staged {n} rogue Buildable(s) → {RECIRC_STAGE} + cleared Wave")
            return 0, out
        out.extend(render_report(findings, backend, matrices))
        return 0, out

    if backend == "github":
        project_number, _ = read_config(repo)
        findings, ctx = scan_github(repo, matrices, project_number, log)
        if mode == "auto-correct":
            apply_github(findings, repo, ctx, log)
            return 0, out
        if ctx is None:
            # The board could not be scanned (owner/project unresolved, or a gh failure already
            # logged above). Report a degraded SKIP, NOT a clean all-clear — a hollow "0 scanned"
            # would read as healthy when the scan never ran (the silent-all-clear anti-pattern).
            # exit 2 → doctor Row 9b classifies this as SKIP ("could not determine"), never PASS.
            out.append("recirc-sweep: SKIP — could not scan the github board (see above); "
                       "NOT a clean all-clear")
            return 2, out
        out.extend(render_report(findings, backend, matrices))
        return 0, out

    # Unknown backend — soft skip.
    if mode == "report":
        out.append(f"recirc-sweep: SKIP — unknown backend '{backend}'")
    return 0, out


def main():
    ap = argparse.ArgumentParser(description="IDC recirculation-intake safety net")
    ap.add_argument("--repo", default=".", help="governed repo root (default: cwd)")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--auto-correct", dest="mode", action="store_const", const="auto-correct",
                      help="SessionEnd hook: mutate the board through the active backend (fail-soft)")
    mode.add_argument("--report", dest="mode", action="store_const", const="report",
                      help="/idc:doctor: read-only, mutate nothing, exit 0")
    ap.add_argument("--tracker", default=None, help="TRACKER.md path (default: <repo>/TRACKER.md)")
    ap.add_argument("--matrices", default=None,
                    help="pillar-matrices dir (default: <repo>/docs/workflow/pillar-matrices)")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    tracker = args.tracker or os.path.join(repo, "TRACKER.md")
    matrices_dir = args.matrices or os.path.join(repo, "docs", "workflow", "pillar-matrices")

    if args.mode == "auto-correct":
        # The SessionEnd hook must NEVER block session exit: swallow every error, always exit 0.
        try:
            _, out = run(repo, args.mode, tracker, matrices_dir)
        except Exception as e:  # noqa: BLE001 — deliberate fail-soft backstop for the hook
            sys.stderr.write(f"idc-recirc-sweep: auto-correct soft-failed: {e}\n")
            sys.exit(0)
        for ln in out:
            sys.stderr.write(ln + "\n")
        sys.exit(0)

    # report mode
    code, out = run(repo, args.mode, tracker, matrices_dir)
    for ln in out:
        print(ln)
    sys.exit(code)


if __name__ == "__main__":
    main()
