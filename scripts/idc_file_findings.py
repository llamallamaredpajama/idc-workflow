#!/usr/bin/env python3
"""idc_file_findings.py — the hook-fired filer (v4 Phase 1, plan §3.3).

Consumes a VALIDATED review verdict and turns its unresolved findings into board work — so a nit
can never strand as reviewer prose (394ec6fe drop points A/B). For every `minor`/`nit` finding and
every `deferrals[]` entry it CREATES a `Stage=Recirculation, Status=Todo` board item itself (no
LLM), carrying:
  * an origin/`Provenance:` line naming the review it came from,
  * an `idc-recirc-source` dedupe marker (a `key`) so re-runs are IDEMPOTENT — zero duplicates,
  * for a `blocks_goal:true` deferral, a parent-blocking dependency link (the parent build issue
    cannot go Done until the deferral is resolved).
`major`/`blocker` findings are NOT filed: they are review FAILs the implementer must fix, not
deferrable nits (the verdict ladder already forces that).

Both backends. github uses the ATOMIC create primitive (idc_gh_board.create_item — Stage+Status
set together, discard on partial failure, the #255/#256 protection). filesystem uses the
idc_tracker_fs create/comment/link CLI. github dedupe fails CLOSED: if the board can't be read to
build the seen-set, it files NOTHING (never risk a duplicate) rather than filing blind.

Fired by the SubagentStop verdict gate on a valid verdict; also runnable by hand / by the finisher.
Invocation: idc_file_findings.py --repo <dir> --verdict <verdict.json> [--parent-issue N]
            [--tracker <TRACKER.md>] [--dry-run]

Note (scope): the discrete github issue *label* and a github-native blocked-by edge are deferred to
Phase 2 (which wraps create_item in the transition engine and can add a labels param / the native
link). Here github records the parent linkage as a `Blocks-parent:` body line; the filesystem
backend gets the real blocked_by edge. The load-bearing behavior — Stage=Recirculation/Todo, the
dedupe marker, and the origin line — lands on BOTH backends now.
"""
import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_review_verdict_check as VC  # noqa: E402
import idc_recirc_sweep as SW          # noqa: E402  — read_backend/read_config/gh_owner/parse_markers/RECIRC_SOURCE_MARKER
import idc_tracker_fs                  # noqa: E402  — the filesystem state reader (DRY with the backend)
import idc_gh_board                    # noqa: E402  — referenced by attribute so tests can monkeypatch

TRK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idc_tracker_fs.py")
MINOR_NIT = {"minor", "nit"}
RECIRC_STAGE = "Recirculation"
TODO = "Todo"


def warn(msg):
    sys.stderr.write(f"idc-file-findings: {msg}\n")


# ── verdict → work items ─────────────────────────────────────────────────────────────────────────
def work_items(verdict):
    """The recirculation items a verdict implies: one per minor/nit finding + one per deferral. Each
    carries a STABLE `key` (finding fingerprint / deferral content hash) that is the idempotency
    anchor — re-filing the same verdict re-derives the same keys, so already-filed items are skipped."""
    pr, issue = verdict.get("pr"), verdict.get("issue")
    origin = f"#{pr}|review" if pr else (f"#{issue}|review" if issue else "review-verdict")
    items = []
    for f in verdict.get("findings", []):
        if not isinstance(f, dict) or f.get("severity") not in MINOR_NIT:
            continue
        fp = str(f.get("fingerprint", "")).strip()
        items.append({
            "kind": "finding", "key": f"finding:{fp}", "origin": origin,
            "what": (str(f.get("evidence", "")).strip() or fp or "review nit"),
            "area": str(f.get("dimension", "review")).strip() or "review",
            "suggested": str(f.get("unblock", "")).strip(),
            "blocks_goal": False,
        })
    for d in verdict.get("deferrals", []):
        if not isinstance(d, dict):
            continue
        what = str(d.get("what", "")).strip()
        h = hashlib.sha1(
            f"{d.get('kind', '')}|{what}|{d.get('suggested_issue', '')}".encode("utf-8")
        ).hexdigest()[:12]
        items.append({
            "kind": "deferral", "key": f"deferral:{h}", "origin": origin,
            "what": what or "deferred obligation",
            "area": str(d.get("kind", "deferral")).strip() or "deferral",
            "suggested": str(d.get("suggested_issue", "")).strip(),
            "blocks_goal": bool(d.get("blocks_goal")),
        })
    return items


def ticket_title(item):
    tag = "recirc(nit)" if item["kind"] == "finding" else "recirc(deferral)"
    return f"{tag}: {item['what'][:60] or 'review finding'}"


def ticket_body(item, parent_issue=None):
    """A drainable Recirculation body (the same five fields idc_recirc_sweep.recirc_ticket_body
    emits, so /idc:recirculate treats a filer ticket exactly like a swept one) plus the extended
    idc-recirc-source marker carrying the dedupe `key`."""
    marker = json.dumps({"origin": item["origin"], "what": item["what"], "key": item["key"]},
                        ensure_ascii=False)
    blocks_line = ""
    if item["blocks_goal"] and parent_issue:
        blocks_line = f"Blocks-parent: #{parent_issue}\n"
    return (
        f"Stage: {RECIRC_STAGE}\n"
        f"Discovered: {item['what']}\n"
        f"Area: {item['area']}\n"
        f"Suggested-scope: {item['suggested'] or item['what']}\n"
        f"Provenance: filed by idc-file-findings from {item['origin']}\n"
        f"PRD-TRD-impact: unknown\n"
        f"{blocks_line}\n"
        f"<!-- idc-recirc-source: {marker} -->\n"
    )


# ── filesystem backend ───────────────────────────────────────────────────────────────────────────
def _fs_state(tracker_path):
    """The TRACKER.md state via the backend's own reader (DRY; correct block parsing). Degrades to
    an empty board if the file is missing/corrupt (idc_tracker_fs.load die()s → SystemExit)."""
    try:
        return idc_tracker_fs.load(tracker_path)
    except SystemExit:
        return {"issues": []}


def _fs_existing_keys(tracker_path):
    keys = set()
    for it in _fs_state(tracker_path).get("issues", []):
        if (it.get("stage") or "") != RECIRC_STAGE:
            continue
        for c in it.get("comments", []):
            for obj in SW.parse_markers(c, SW.RECIRC_SOURCE_MARKER):
                k = obj.get("key")
                if k:
                    keys.add(k)
    return keys


def _trk(tracker_path, *args):
    import subprocess
    return subprocess.run([sys.executable, TRK, "--tracker", tracker_path, *args],
                          capture_output=True, text=True)


def run_filesystem(verdict, tracker_path, parent_issue, dry_run):
    if not os.path.isfile(tracker_path):
        warn(f"filesystem backend: no TRACKER.md at {tracker_path} — nothing filed")
        return 3
    items = work_items(verdict)
    existing = _fs_existing_keys(tracker_path)
    existing_numbers = {it.get("number") for it in _fs_state(tracker_path).get("issues", [])}
    filed = skipped = failed = 0
    for it in items:
        if it["key"] in existing:
            skipped += 1
            continue
        if it["blocks_goal"] and parent_issue and parent_issue not in existing_numbers:
            warn(f"filesystem: parent issue #{parent_issue} not found for blocks_goal item {it['key']} — nothing filed")
            failed += 1
            continue
        if dry_run:
            existing.add(it["key"])
            filed += 1
            continue
        r = _trk(tracker_path, "create", "--title", ticket_title(it),
                 "--stage", RECIRC_STAGE, "--status", TODO)
        if r.returncode != 0:
            warn(f"filesystem: create failed for {it['key']} ({r.stderr.strip()[:120]})")
            failed += 1
            continue
        num = r.stdout.strip()
        if it["blocks_goal"] and parent_issue:
            lk = _trk(tracker_path, "link", "--parent", num, "--child", str(parent_issue), "--kind", "blocks")
            if lk.returncode != 0:
                warn(f"filesystem: parent-block link #{num}->{parent_issue} failed ({lk.stderr.strip()[:120]})")
                failed += 1
                continue
        cm = _trk(tracker_path, "comment", "--num", num, "--body", ticket_body(it, parent_issue))
        if cm.returncode != 0:
            warn(f"filesystem: comment/marker failed for #{num} ({cm.stderr.strip()[:120]})")
            failed += 1
            continue
        existing.add(it["key"])
        filed += 1
    print(f"idc-file-findings: filed {filed}, skipped {skipped} duplicate(s), failed {failed} (backend=filesystem)")
    return 3 if failed else 0


# ── github backend ───────────────────────────────────────────────────────────────────────────────
def _github_existing_keys(repo, owner, project):
    """The set of already-filed `key`s from existing Recirculation tickets' idc-recirc-source
    markers. Raises BoardReadError (propagated) if the board can't be read — the caller fails CLOSED
    rather than filing blind (a silent empty set would risk duplicates)."""
    keys = set()
    for it in idc_gh_board.fetch_items(owner, project, repo):
        if (it.get("stage") or "") != RECIRC_STAGE:
            continue
        num = (it.get("content") or {}).get("number")
        if num is None:
            continue
        ok, body_out, err = SW.gh(["issue", "view", str(num), "--json", "body"], repo)
        if not ok:
            raise idc_gh_board.BoardReadError(
                f"could not read existing Recirculation issue #{num} body ({err.strip()[:120]})")
        try:
            body = json.loads(body_out).get("body") or ""
        except (ValueError, TypeError) as e:
            raise idc_gh_board.BoardReadError(
                f"could not parse existing Recirculation issue #{num} body ({e})")
        for obj in SW.parse_markers(body, SW.RECIRC_SOURCE_MARKER):
            k = obj.get("key")
            if k:
                keys.add(k)
    return keys


def file_github(verdict, repo, owner, project, existing_keys, parent_issue, dry_run):
    """Create one atomic Recirculation/Todo item per un-filed nit/deferral. Returns the count filed.
    `existing_keys` is the caller-supplied dedupe set (fail-closed to build it before calling)."""
    items = work_items(verdict)
    filed = 0
    for it in items:
        if it["key"] in existing_keys:
            continue
        existing_keys.add(it["key"])
        if dry_run:
            filed += 1
            continue
        try:
            idc_gh_board.create_item(owner, project, repo, ticket_title(it),
                                     ticket_body(it, parent_issue), RECIRC_STAGE, TODO)
        except idc_gh_board.BoardReadError as e:
            warn(f"github: create failed for {it['key']} ({str(e)[:120]}) — surfaced, not counted")
            continue
        filed += 1
    return filed


def run_github(verdict, repo, owner, project, parent_issue, dry_run):
    if not (owner and project):
        warn("github backend: could not resolve owner/project_number — nothing filed")
        return 3
    try:
        existing = _github_existing_keys(repo, owner, project)
    except idc_gh_board.BoardReadError as e:
        warn(f"github: dedupe board read failed ({str(e)[:120]}) — filing NOTHING to avoid "
             "duplicates (will retry next run)")
        return 3
    filed = file_github(verdict, repo, owner, project, existing, parent_issue, dry_run)
    print(f"idc-file-findings: filed {filed} (backend=github)")
    return 0


# ── entry point ──────────────────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="File a verdict's nits/deferrals as Recirculation board items.")
    ap.add_argument("--repo", required=True, help="the governed repo root")
    ap.add_argument("--verdict", required=True, help="path to the validated verdict JSON")
    ap.add_argument("--parent-issue", type=int, default=None,
                    help="board issue the review's PR implements (blocks_goal link target); "
                         "defaults to the verdict's `issue` field")
    ap.add_argument("--tracker", default=None, help="TRACKER.md path (filesystem; default <repo>/TRACKER.md)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    try:
        with open(a.verdict, encoding="utf-8") as fh:
            verdict = json.load(fh)
    except (OSError, ValueError) as e:
        warn(f"cannot read verdict {a.verdict}: {e}")
        sys.exit(2)

    problems = VC.check(verdict)
    if problems:
        warn(f"refusing to file — verdict does not validate: {'; '.join(problems[:3])}")
        sys.exit(2)

    parent = a.parent_issue if a.parent_issue is not None else verdict.get("issue")
    try:
        parent = int(parent) if parent is not None else None
    except (TypeError, ValueError):
        parent = None

    backend = SW.read_backend(a.repo) or "filesystem"
    if backend == "github":
        owner = SW.gh_owner(a.repo)
        project_number, _ = SW.read_config(a.repo)
        sys.exit(run_github(verdict, a.repo, owner, project_number, parent, a.dry_run))
    tracker = a.tracker or os.path.join(a.repo, "TRACKER.md")
    sys.exit(run_filesystem(verdict, tracker, parent, a.dry_run))


if __name__ == "__main__":
    main()
