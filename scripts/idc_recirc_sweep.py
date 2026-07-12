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

A third, **surface-only** dimension catches a **dropped larger-loop handoff**: an admitted
`Stage = Consideration` / `Status = Todo` item left with NO decomposition — no `Stage = Buildable`
child issue and no in-flight `Stage = Planning` pointer anywhere on the board (Plan never ran on it).
It is **never auto-mutated** (defense-in-depth — re-staging a consideration could erase an operator's
admission); it is reported by `--report` only. Conservative: any live Buildable/Planning item silences
every surface, so a healthy Plan/Build lane is never second-guessed.

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
import time

# Reuse the sibling helpers (same directory) rather than re-implement matrix parsing / fs writes.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_matrix_check  # noqa: E402  — parse_matrix (constrained-YAML pillar scanner)
import idc_tracker_fs    # noqa: E402  — load/save/find + atomic TRACKER.md writer
import idc_gh_board      # noqa: E402  — shared paginating board reader + atomic create_item (#130)
import idc_board_lint    # noqa: E402  — OPERATOR_GATE_PREFIX (single-sourced marker)
import idc_transition as TE  # noqa: E402  — the engine's canonical journal_append (journal every door, #150)

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
SURFACE_DROPPED = "surface-dropped"  # admitted Consideration, no decomposition — surface-only, never mutated

RECIRC_STAGE = "Recirculation"
BUILDABLE_STAGE = "Buildable"
CONSIDERATION_STAGE = "Consideration"
PLANNING_STAGE = "Planning"
TODO_STATUS = "Todo"
DONE_STATUS = "Done"

# ── journal doors (issue #150) ────────────────────────────────────────────────
# The sweep is a sanctioned CODE door: it stamps Stage=Recirculation (re-stage) and files new
# Recirculation tickets, both OUTSIDE the transition engine. Each such mutation must append the
# engine's canonical journal record, or the janitor's replay reconciliation reports documented sweep
# traffic as a false journal↔board divergence. A re-stage is a Stage-only move (Status untouched), so
# it journals under this dedicated op-kind; a filed ticket is a create, journaled as `recirculate-intake`
# (the engine's recirc-inbox create op — replay's create watermark then recognises it as journaled).
RESTAGE_JOURNAL_OP = "recirc-restage"
INTAKE_JOURNAL_OP = "recirculate-intake"
# A Buildable/Planning item is in-flight decomposition unless it is DONE. Only Done is excluded: Done
# items accumulate on every mature board, so counting them would permanently silence the surface (the
# bug this guards). Every NON-Done status — Todo, In Progress, AND Blocked (the caps' park-a-runaway
# state: Stage=Buildable + Status=Blocked) — is decomposition that DID happen, so it silences the
# surface; excluding Blocked would falsely re-surface a consideration whose child was merely parked.


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


def is_operator_gate(title):
    """True if this issue is an `[operator-action]` gate — the human requirements gate, NOT build work.

    Uses the single-sourced `idc_board_lint.OPERATOR_GATE_PREFIX` marker so the sweep, the drain
    (`idc_autorun_drain._is_build_candidate`'s title subclause), and board-lint can't drift on the
    prefix string. Excluded at the candidate layer so a gate (empty `Stage` → reads Buildable, no
    provenance) isn't swept and re-staged to Recirculation every fixpoint pass. PURE (unit-testable)."""
    return str(title or "").strip().startswith(idc_board_lint.OPERATOR_GATE_PREFIX)


def dropped_handoff_numbers(items):
    """The admitted `Stage = Consideration` / `Status = Todo` issue numbers that show a DROPPED
    larger-loop handoff — admitted (Think PR merged) yet never decomposed: NO `Stage = Buildable`
    child issue and NO in-flight `Stage = Planning` pointer anywhere on the board (Plan never ran on
    it). PURE, IO-free (unit-testable like decide()).

    `items` is a list of `{"number","stage","status"}` board-meta dicts (the stage/status both
    backends already read). Conservative by construction: any NON-Done Buildable or Planning item is
    decomposition activity and silences EVERY surface — we cannot attribute a specific buildable to a
    specific consideration, so a live Plan/Build lane is never second-guessed (no false surface). The
    match is STATUS-aware on exactly ONE boundary — Done: a Done Buildable is finished work, and Done
    items accumulate on every board past day-1, so counting them would permanently mask a genuinely
    dropped handoff. Every other status counts as decomposition that DID happen — including **Blocked**,
    the caps' park-a-runaway state (Stage=Buildable + Status=Blocked), so a consideration whose child was
    merely parked is not falsely re-surfaced. The matched converse — admitted considerations with NO
    non-Done Plan/Build work — is the unmistakable dropped handoff this catches. An empty/missing `stage`
    defaults to Buildable (the legacy 4-field default), so a bare todo issue counts as activity too."""
    considerations = [it.get("number") for it in items
                      if (it.get("stage") or "") == CONSIDERATION_STAGE
                      and it.get("status") == TODO_STATUS]
    if not considerations:
        return []
    decomposition_active = any(
        (it.get("stage") or BUILDABLE_STAGE) in (BUILDABLE_STAGE, PLANNING_STAGE)
        and it.get("status") != DONE_STATUS for it in items)
    return [] if decomposition_active else considerations


def dropped_handoff_findings(items):
    """SURFACE_DROPPED Findings (surface-only — never mutated) for each dropped handoff in `items`."""
    return [Finding(num, SURFACE_DROPPED,
                    "admitted consideration, no Buildable child / no in-flight plan")
            for num in dropped_handoff_numbers(items) if num is not None]


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


# ── canonical journal door (issue #150) ──────────────────────────────────────
def _journal_restage(repo, backend, tracker_rel, number, item_id=None, heal=None):
    """Append the canonical transition-journal record for a sanctioned Stage=Recirculation re-stage.

    The sweep re-stages a rogue OUTSIDE the transition engine, so without this the janitor's replay
    reconciliation flags the swept item as a false Stage divergence. Best-effort like every
    journal_append (the finisher/janitor/engine share the same contract): the re-stage already
    landed, so a journal failure warns and never fails the fail-soft sweep. A re-stage moves ONLY the
    Stage (Status is untouched), so it records `to.stage` alone — replay keeps the item's prior Status
    from its create/move records and reconstructs the swept item to an exact match.

    `heal` (heal_unjournaled_inbox only) stamps a disclosure field on the record: a BACKFILL for an
    item the sweep did NOT itself re-stage must never read as if it had (codex round-11 P2).

    Returns journal_append's success signal (True iff the record durably landed) — the sweep's
    re-stage path ignores it (fail-soft, the board move already landed), but the journal-backfill
    heal REQUIRES it: the record IS the whole point of the heal, so a swallowed append must never be
    counted as healed (codex round-14 P2)."""
    kw = {"num": number, "to_stage": RECIRC_STAGE, "agent": "recirc-sweep",
          "project_item_id": item_id}
    if heal:
        kw["heal"] = heal
    return TE.journal_append(repo, RESTAGE_JOURNAL_OP, backend, tracker_rel, kw)


def heal_unjournaled_inbox(repo, backend, tracker_rel, candidates, read_text, log):
    """Backfill the journal for a VALID Recirculation-inbox item that has NO sanctioned inbox record
    (codex round-11 P2): the intake/restage landed on the board but its best-effort journal append
    failed. Without this the item is PERMANENTLY undrainable — the drained guard's corroboration
    fails closed, the filer's marker-dedupe never re-files it, the sweep's idempotent re-stage skip
    never re-journals it, and the janitor's replay only REPORTS the divergence.

    The sweep is already the sanctioned, journaled judge of what belongs on the inbox (it re-stages
    any marker-bearing rogue through this same journal door), so ratifying an already-staged item
    with the SAME validity predicate the drained guard uses (idc_transition._recirc_evidence) adds
    no new trust — and the record it emits DISCLOSES itself via heal=journal-backfill. HONEST
    RESIDUAL (#151): a well-formed forged marker is ratified too; corroboration proves a sanctioned
    producer's journaled decision, never marker authenticity — exactly the trust level of the
    sweep's own rogue re-stage door.

    candidates: [{"number": int, "item_id": node-id-or-None}] — Stage=Recirculation, non-Done items.
    read_text(candidate) -> the item's body+comments text; called ONLY for uncorroborated items, so
    a fully-journaled inbox costs zero extra issue reads. Self-deduping: the emitted record IS the
    corroboration the next run finds. A corrupt/unreadable journal SKIPS the heal (never backfill
    blind — corruption is the janitor's reconciliation job). Fail-soft; returns the number healed."""
    if not candidates:
        return 0
    import idc_journal_replay as RP
    entries, err = RP.scan_journal_strict(
        os.path.join(repo, "docs", "workflow", "transition-journal.ndjson"))
    if err:
        log(f"journal-heal: journal unreadable ({err}) — skipping the inbox backfill this sweep")
        return 0
    sanctioned = (RESTAGE_JOURNAL_OP, INTAKE_JOURNAL_OP)

    def named(entry, num, item_id):
        if RP.journal_item_id(entry) == num:
            return True
        return item_id is not None and entry.get("project_item_id") == item_id

    healed = 0
    unwritable = 0
    for c in candidates:
        num, item_id = c["number"], c.get("item_id")
        if any(isinstance(e, dict) and e.get("op") in sanctioned and named(e, num, item_id)
               for e in entries):
            continue   # already corroborated — the self-dedupe that keeps this idempotent
        try:
            text = read_text(c)
        except idc_gh_board.RateLimitError:
            # A throttle on a heal-side read (github only — the fs read_text never raises): the
            # REMAINING uncorroborated candidates would each fire the same doomed `gh issue view`, so
            # DEFER them to the next sweep (codex round-15 P2). Non-"rate-limited"/"deferring"-phrased,
            # per the round-14 collision note (recirc-sweep-atomic-intake.sh counts those words).
            log("journal-heal: throttled on a heal read — skipping the remaining backfill candidates "
                "this sweep (they would throttle too); retry on the next sweep")
            break
        if TE._recirc_evidence(text) is None:
            continue   # no VALID provenance marker — never ratify a bare Recirculation item
        # The heal's WHOLE PURPOSE is the journal record (the board item already exists), so a
        # SWALLOWED journal_append (permissions/full disk/lock error) must NOT be counted as healed:
        # no corroborating record landed, the ticket stays undrainable, and counting it would report a
        # false heal every sweep (codex round-14 P2). Only count a CONFIRMED backfill.
        if not _journal_restage(repo, backend, tracker_rel, num, item_id=item_id, heal="journal-backfill"):
            unwritable += 1
            continue
        log(f"journal-heal: backfilled the sanctioned inbox record for Recirculation ticket #{num} "
            "(its intake/restage journal record was lost — the backfill is disclosed in the record)")
        healed += 1
    if unwritable:
        # One concise line, not per-item spam: surface that the journal could not be written (so the
        # strand persists) without a false success and without hammering the log every sweep.
        log(f"journal-heal: {unwritable} inbox backfill(s) could not be journaled (append failed — the "
            "journal may be unwritable); those tickets stay stranded and will retry next sweep")
    return healed


def _github_issue_number(item_id, repo, attempts=3):
    """Issue-number read-back for a freshly filed Recirculation ticket (the journal `item` key).

    create_item JUST wrote this exact item, so the node read is near-certain — but a NUMBERLESS intake
    record cannot self-heal (the source-marker dedupe skips the already-filed ticket on every later
    sweep, and the janitor only REPORTS divergence, never backfills), so resolving the number NOW
    matters. A transient read failure is therefore retried with a short backoff. Returns None only if
    every attempt fails — the caller then surfaces the ticket and does NOT count it as filed."""
    for attempt in range(attempts):
        try:
            item = idc_gh_board.fetch_item(item_id, repo)
        except Exception as e:  # noqa: BLE001 — retry a transient node read, then give up (best-effort)
            if attempt + 1 < attempts:
                time.sleep(0.2 * (attempt + 1))
                continue
            sys.stderr.write(f"idc-recirc-sweep: could not resolve filed ticket issue number for journal: {e}\n")
            return None
        num = (item.get("content") or {}).get("number")
        if isinstance(num, int):
            return num
        if isinstance(num, str) and num.isdigit():
            return int(num)
        return None  # item resolved but carries no number (unexpected for a real issue) — retry won't help
    return None


def _journal_intake(repo, item_id, number, title):
    """Append the canonical journal record for a filed Recirculation ticket (issue #150). create_item
    landed Stage=Recirculation + Status=Todo atomically, so the create journals BOTH via to.{stage,
    status}; recording it under the engine's recirculate-intake op lets replay's create watermark
    recognise the ticket as journaled. Best-effort/fail-soft; `number` may be None if the read-back
    failed, in which case the record still carries the project_item_id."""
    TE.journal_append(repo, INTAKE_JOURNAL_OP, "github", None,
                      {"num": number, "title": title, "to_stage": RECIRC_STAGE,
                       "to_status": TODO_STATUS, "agent": "recirc-sweep", "project_item_id": item_id})


def _heal_partial_intake(repo, ctx, partial, log):
    """Complete a throttle-partial Recirculation ticket IN PLACE: set Status=Todo (one setField — no new
    issue, no duplicate) + journal the now-complete intake. The partial is a ticket create_item left
    Stage=Recirculation with an EMPTY Status when a rate limit hit between its Stage and Status writes;
    without healing, the marker-dedupe would skip it FOREVER (#150 / codex R4 P1a — SELF-HEAL, not skip).
    Fail-soft: a gh failure (BoardReadError covers BoardWriteError + RateLimitError) logs and returns
    False (re-healed next sweep). Returns True iff the heal landed."""
    number, item_id = partial["number"], partial["item_id"]
    if not item_id:
        return False
    try:
        idc_gh_board.set_status(ctx["owner"], ctx["project_number"], repo, item_id, TODO_STATUS)
    except idc_gh_board.BoardReadError as e:
        log(f"github: could not heal partial Recirculation ticket #{number} "
            f"({str(e).strip()[:120]}) — will retry next sweep")
        return False
    _journal_intake(repo, item_id, number, f"heal recirc intake #{number}")
    log(f"github: healed throttle-partial Recirculation ticket #{number} → Status={TODO_STATUS}")
    return True


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
        if is_operator_gate(it.get("title")):
            continue  # an [operator-action] gate is a human gate, not rogue build work (drain parity)
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
    # Dropped larger-loop handoff (surface-only): an admitted Consideration with no decomposition.
    # Matrix-independent (Plan, which writes the matrix, never ran), so it rides the full issue list.
    meta = [{"number": it.get("number"), "stage": it.get("stage"), "status": it.get("status")}
            for it in issues if isinstance(it, dict)]
    findings += dropped_handoff_findings(meta)
    return findings, state


def apply_filesystem(findings, state, tracker_path, repo):
    """Mutate TRACKER.md: re-stage each rogue to Recirculation + clear its Wave. Idempotent — an
    issue already at Recirculation with empty Wave is a no-op, so a re-run changes nothing.

    Each re-stage that actually lands is journaled AFTER the durable save (issue #150) so the
    janitor's replay reconciliation reconstructs the swept item to an exact match. The idempotent
    skip above means a re-run neither mutates NOR re-journals."""
    changed = 0
    restaged = []
    for f in findings:
        if f.action != RESTAGE:
            continue
        it = idc_tracker_fs.find(state, f.number)
        if it.get("stage") == RECIRC_STAGE and not it.get("wave"):
            continue  # already corrected — idempotent
        it["stage"] = RECIRC_STAGE
        it["wave"] = ""
        restaged.append(f.number)
        changed += 1
    if changed:
        idc_tracker_fs.save(tracker_path, state)
        tracker_rel = os.path.relpath(tracker_path, repo)
        for number in restaged:
            _journal_restage(repo, "filesystem", tracker_rel, number)
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
    ctx = {"owner": owner, "project_node": project_node, "project_number": project_number,
           # A throttle-partial is a Recirculation item with an EMPTY Status (create_item left it when a
           # rate limit hit between its Stage and Status writes). Flag their presence from THIS single
           # board read so apply_github heals them independently of captures WITHOUT a second scan on a
           # clean sweep (#150 codex R5 P1c — self-heal must not hide inside the new-ticket path).
           "has_partials": any((it.get("stage") or "") == RECIRC_STAGE and not it.get("status")
                               and (it.get("content") or {}).get("number") is not None for it in items),
           # The journal-backfill heal's candidate set (codex round-11 P2), from THIS same board read:
           # every live (non-Done, Status set — empty-Status partials heal via the path above, which
           # journals their intake) Recirculation item. apply_github reads bodies only for the ones
           # the journal does not already corroborate, so a healthy inbox costs no extra gh calls.
           "recirc_candidates": [
               {"number": (it.get("content") or {}).get("number"), "item_id": it.get("id")}
               for it in items
               if (it.get("stage") or "") == RECIRC_STAGE
               and it.get("status") and it.get("status") != DONE_STATUS
               and (it.get("content") or {}).get("number") is not None]}

    scanned = []
    for it in items:
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:               # a draft item carries no issue number
            continue
        if is_operator_gate(content.get("title")):
            continue  # an [operator-action] gate is a human gate, not rogue build work (drain parity)
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
    # Dropped larger-loop handoff (surface-only): an admitted Consideration with no decomposition,
    # read straight off the board meta (the whole-board stage/status both lanes already carry).
    meta = [{"number": (it.get("content") or {}).get("number"),
             "stage": it.get("stage"), "status": it.get("status")} for it in items]
    findings += dropped_handoff_findings(meta)
    return findings, ctx


def github_existing_sources(repo, ctx, log):
    """Scan the WHOLE board (paginated) for Recirculation tickets carrying the hidden source marker and
    split them by completeness:

      * `seen`     — {(origin, what)} for FULLY-filed tickets (Status set): the stateless dedupe set
                     that keeps ticket-filing idempotent across runs.
      * `partials` — [{"number","item_id","keys"}] for tickets whose Stage=Recirculation + source
                     marker landed but whose Status is EMPTY — a throttle-partial create_item left when
                     a rate limit hit between its Stage and Status writes. The caller HEALS these
                     (completes Status=Todo in place) instead of skipping them FOREVER (#150 / codex R4
                     P1a); a source marker + empty Status is unambiguously such a partial (only
                     create_item ever writes that marker).

    Returns (seen, partials) on success, or None when the board read FAILS — a VISIBLE degraded state
    (logged) the caller treats as "cannot dedupe → do not file" (fail-closed against blind duplicates)."""
    seen = set()
    partials = []
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
        keys = [(str(obj.get("origin", "")), str(obj.get("what", "")).strip())
                for obj in parse_markers(body, RECIRC_SOURCE_MARKER)]
        if not keys:
            continue
        if it.get("status"):          # a real, fully-filed ticket → dedupe
            seen.update(keys)
        else:                         # marker present but EMPTY Status → a throttle-partial to HEAL
            partials.append({"number": number, "item_id": it.get("id"), "keys": keys})
    return seen, partials


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
        # Journal the sanctioned Stage-only re-stage (issue #150). f.number is the issue number, f.item_id
        # the project node id; the Status is untouched, so only to.stage is recorded.
        _journal_restage(repo, "github", None, f.number, item_id=f.item_id)
        changed += 1

    # Ticket capture + partial healing. The scan runs when there is EITHER new work to file (captures)
    # OR a throttle-partial to heal (ctx.has_partials) — so a partial from a PRIOR sweep is healed even
    # when THIS sweep re-staged its source out of the Buildable lane, leaving no capture (#150 codex R5
    # P1c). Only NEW-ticket filing is gated on captures (the create loop below no-ops when captures==[]).
    captures = [c for f in findings for c in f.captures]
    throttled = False   # a mid-create rate limit STOPS the sweep (incl. the heal pass) — see below
    if captures or ctx.get("has_partials"):
        sources = github_existing_sources(repo, ctx, log)
        if sources is None:
            # The dedupe board read failed (logged above) — do NOT file/heal blind (would risk duplicates).
            return changed
        already, partials = sources
        # SELF-HEAL throttle-partials (marker present, EMPTY Status) IN PLACE — complete + journal them
        # instead of skipping them forever (#150 / codex R4 P1a). Independent of captures. DEDUPE the
        # partial's keys WHETHER OR NOT the heal lands (#150 codex R6): the marker is ALREADY on the board
        # (an incomplete ticket), so a matching capture below must never create a DUPLICATE — a heal that
        # fails transiently just retries next sweep (the partial stays empty-Status → re-detected). Count
        # only a successful heal as a board change.
        for p in partials:
            already.update(p["keys"])
            if _heal_partial_intake(repo, ctx, p, log):
                changed += 1
        for c in captures:
            key = (c["origin"], c["what"])
            if key in already:
                continue
            already.add(key)             # in-run dedupe too (two markers, same scope)
            body = recirc_ticket_body(c, c.get("area", ""), c.get("suggested_scope", ""))
            title = f"recirc: {c['what'][:60] or 'discovered scope'}"
            # Mint the ticket through the ATOMIC create primitive (issue #130): create_item sets Stage
            # AND Status together and DISCARDS a partial, so the filed ticket can NEVER be the
            # Stage=Recirculation/empty-Status item the old issue-create → item-add → item-edit chain
            # left behind (the #255/#256 empty-Status pointer class the drain trips over). It also
            # read-back verifies the atomic-verified item id, so there is no separate add/edit-failure
            # partial to gate — a raise IS the failure signal. Fail-soft per capture: one failed create
            # (BoardWriteError / RateLimitError, both BoardReadError subclasses) logs and continues,
            # never aborting the sweep.
            try:
                iid = idc_gh_board.create_item(owner, project_number, repo, title, body,
                                               RECIRC_STAGE, TODO_STATUS)
            except idc_gh_board.RateLimitError as e:
                # A throttle mid-create is RESUMABLE, but the sweep is a fail-soft SessionEnd hook with
                # no pause/resume: create_item RE-RAISES RateLimitError WITHOUT discarding a partial (by
                # design, for a rate-limit-aware caller). So DEFER filing (RateLimitError is a
                # BoardReadError subclass — catch it FIRST) rather than hammer the throttled API or mask
                # it as a hard failure, and STOP (the remaining captures would throttle too). Any partial
                # create_item left is a Stage-set/empty-Status item that board-lint / doctor Row 9 (the
                # #255/#256 detector) surfaces for reconciliation; the next unthrottled sweep re-drives
                # any capture whose ticket body (with the source marker) was never written.
                log(f"github: ticket-filing rate-limited ({e}) — deferring the remaining "
                    "captures to the next sweep")
                throttled = True
                break
            except idc_gh_board.BoardReadError as e:  # BoardWriteError (partial already discarded) — hard fail
                log(f"github: ticket for {c['origin']} failed ({str(e).strip()[:120]}) — not counted as filed")
                continue
            # Journal the filed create as the engine's recirc-inbox create op (issue #150) so replay's
            # create watermark recognises the ticket as journaled, not a bypassed board-only item.
            # The journal keys the item by its ISSUE NUMBER; replay ignores project_item_id, so a record
            # with no number would leave the live ticket looking board-only (a false divergence). Only
            # report/count the filing as clean once the number is journaled — a resolve failure (rare:
            # create_item just wrote this very item) is SURFACED and NOT counted, so the janitor/next
            # sweep reconciles it rather than a silent-success hiding an unreconcilable ticket.
            number = _github_issue_number(iid, repo)
            _journal_intake(repo, iid, number, title)
            if number is None:
                # The ticket IS validly on the board (create_item is atomic), but its journal record
                # has no issue number, so replay/janitor will surface it as board-only. It will NOT
                # self-heal — the source-marker dedupe skips this ticket on later sweeps — so DON'T
                # report it as cleanly filed: surface it for operator reconciliation (rare, since the
                # number resolve above retries).
                log(f"github: filed Recirculation ticket for {c['origin']} but its issue number could "
                    f"NOT be resolved for the journal ({iid}) — surfaced, not counted as filed "
                    "(needs operator reconciliation; will not self-heal)")
                continue
            log(f"github: filed Recirculation ticket for {c['origin']} ({c['what'][:60]})")
            changed += 1

    # A mid-create RATE LIMIT stops the whole sweep, not just ticket filing: the heal pass below fires
    # a `gh issue view` per uncorroborated candidate (via _github_issue_text), so continuing into it
    # while throttled would hammer the API with doomed reads — in the SessionEnd hook (codex round-14
    # P2). Match the capture loop's defer-to-next-sweep discipline: skip the heal and return.
    if throttled:
        # (wording avoids "rate-limited"/"deferring" — the capture loop's own throttle-STOP signals,
        # which recirc-sweep-atomic-intake.sh counts — so this heal-skip line never inflates them.)
        log("github: throttled — skipping the journal-backfill heal this sweep "
            "(its per-candidate issue reads would throttle too; retry on the next sweep)")
        return changed

    # Journal-backfill heal (codex round-11 P2): ratify any live Recirculation item whose sanctioned
    # inbox record was lost (see heal_unjournaled_inbox). Runs LAST so records this very sweep just
    # journaled (re-stages, intakes, partial heals) already corroborate their items — no double line.
    changed += heal_unjournaled_inbox(repo, "github", None, ctx.get("recirc_candidates") or [],
                                      lambda c: _github_issue_text(c["number"], repo), log)
    return changed


def _github_issue_text(number, repo):
    """One issue's body + comment bodies as a single text blob (the heal's marker source). Fail-soft:
    an unreadable issue returns "" — the heal then finds no valid marker and skips (never ratify
    what it could not read). EXCEPT a rate-limited read RAISES RateLimitError so the heal DEFERS the
    remaining candidates instead of firing the same doomed `gh issue view` for each (codex round-15
    P2 — the round-14 throttle short-circuit only covered create_item, not these heal reads)."""
    okb, body_out, err = gh(["issue", "view", str(number), "--json", "body,comments"], repo)
    if not okb:
        if idc_gh_board._is_rate_limit_stderr(err):
            # reset omitted: a fail-soft SessionEnd defer needs no pause-and-resume epoch, and skipping
            # the extra `gh api rate_limit` probe avoids one more call while already throttled.
            raise idc_gh_board.RateLimitError()
        return ""
    try:
        jd = json.loads(body_out)
    except json.JSONDecodeError:
        return ""
    return (jd.get("body") or "") + "\n" + \
        "\n".join(str((c or {}).get("body", "")) for c in jd.get("comments", []))


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
    # A dropped larger-loop handoff is matrix-INDEPENDENT (an admitted consideration that was never
    # decomposed usually has no matrix yet — Plan, which writes the matrix, never ran), so it surfaces
    # even when the provenance sweep is skipped for want of a matrix.
    dropped = [f for f in findings if f.action == SURFACE_DROPPED]
    for f in dropped:
        lines.append(f"#{f.number}: dropped larger-loop handoff — admitted consideration not "
                     f"decomposed (no Buildable child / no in-flight plan); surface only")
    if matrices is None:
        if dropped:
            lines.append(f"recirc-sweep: {len(dropped)} dropped handoff(s) surfaced; provenance "
                         "sweep skipped — no pillar matrix")
        else:
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
    # `scanned` is the buildable-lane count only — SURFACE_DROPPED findings are considerations, not
    # scanned Buildables, so they never inflate it.
    scanned = sum(1 for f in findings if f.action != SURFACE_DROPPED)
    if not rogue and not ambiguous and not captures and not dropped:
        lines.append(f"recirc-sweep: clean ({scanned} buildable scanned)")
    else:
        note = "" if backend != "filesystem" else " — filesystem: ticket-capture is github-only"
        # The dropped clause is conditional (omitted when 0) so the existing rogue/ambiguous/capture
        # summary stays byte-identical for boards with no dropped handoff.
        dropped_clause = f", {len(dropped)} dropped handoff(s)" if dropped else ""
        lines.append(f"recirc-sweep: {len(rogue)} rogue, {len(ambiguous)} ambiguous, "
                     f"{len(captures)} untickered marker(s){dropped_clause} of {scanned} buildable scanned{note}")
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
            n = apply_filesystem(findings, state, tracker, repo)
            if n:
                log(f"filesystem: re-staged {n} rogue Buildable(s) → {RECIRC_STAGE} + cleared Wave")
            # Journal-backfill heal (codex round-11 P2) — AFTER apply, so re-stages this sweep just
            # journaled already corroborate their items. `state` reflects the applied re-stages
            # (apply_filesystem mutates it in place); markers ride comments on this backend.
            issues = [it for it in state.get("issues", []) if isinstance(it, dict)]
            candidates = [{"number": it.get("number"), "item_id": None} for it in issues
                          if it.get("stage") == RECIRC_STAGE and it.get("status") != DONE_STATUS
                          and it.get("number") is not None]
            texts = {it.get("number"): "\n".join(str(c) for c in (it.get("comments") or [])
                                                 if c is not None) for it in issues}
            heal_unjournaled_inbox(repo, "filesystem", os.path.relpath(tracker, repo), candidates,
                                   lambda c: texts.get(c["number"], ""), log)
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
