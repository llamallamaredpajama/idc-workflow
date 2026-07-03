#!/usr/bin/env python3
"""idc_tracker_fs.py — the IDC v2 filesystem tracker backend.

A zero-setup, executable implementation of the portable Tracker interface
(`WORKFLOW.md §3`) over a single human-readable `TRACKER.md`. It is the backend that
`tracker-config.yaml::backend = filesystem` resolves through, and the deterministic
substrate the sandbox smoke tests run against (no GitHub required).

State of record is a JSON block embedded in TRACKER.md between
`<!-- idc-tracker-state:begin -->` / `<!-- idc-tracker-state:end -->`; a markdown board table is
re-rendered beneath it on every write for humans. Standard library only.

Six core ops (createTicket/setField/link/move/query/comment) + convenience
(init/claim/block/close/show). Five fields: Status, Wave, Phase, Domain, Stage. Status is
one of Blocked | Todo | In Progress | Done; Stage is the column-grouping field, one of
Consideration | Planning | Buildable | Recirculation (upstream pointer items ride
Consideration/Planning, buildable issues ride Buildable, and Recirculation is the non-Buildable
inbox for scope discovered mid-build — drained by /idc:recirculate, never claimed as build work).
Dependencies are native blocked-by; claims are a Status flip + a comment naming the agent;
per-issue fix attempts live on `attempt`.
"""
import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager

STATUSES = ("Blocked", "Todo", "In Progress", "Done")
STAGES = ("Consideration", "Planning", "Buildable", "Recirculation")
FIELDS = ("Status", "Wave", "Phase", "Domain", "Stage")
BEGIN = "<!-- idc-tracker-state:begin -->"
END = "<!-- idc-tracker-state:end -->"


def die(msg):
    sys.stderr.write(f"idc-tracker-fs: {msg}\n")
    sys.exit(1)


def empty_state():
    return {"next_number": 1, "issues": []}


def load(path, allow_missing=False):
    if not os.path.exists(path):
        if allow_missing:
            return empty_state()
        die(f"TRACKER not found at {path} — run `init` first")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(re.escape(BEGIN) + r"\s*```json\s*(.*?)\s*```\s*" + re.escape(END), text, re.S)
    if not m:
        die(f"TRACKER at {path} has no idc:tracker JSON block (corrupt or not an IDC tracker)")
    try:
        state = json.loads(m.group(1))
    except json.JSONDecodeError as e:
        die(f"TRACKER JSON block is invalid: {e}")
    state.setdefault("next_number", 1)
    state.setdefault("issues", [])
    return state


def find(state, num):
    for it in state["issues"]:
        if it.get("number") == num:
            return it
    die(f"issue #{num} not found")


def render_table(state):
    rows = ["| # | Title | Status | Stage | Wave | Phase | Domain | Blocked-by |",
            "|---|-------|--------|-------|------|-------|--------|------------|"]
    for it in sorted(state["issues"], key=lambda x: x["number"]):
        bb = ", ".join(f"#{n}" for n in it.get("blocked_by", [])) or "—"
        rows.append(f"| {it['number']} | {it['title']} | {it['status']} | "
                    f"{it.get('stage','') or '—'} | "
                    f"{it.get('wave','') or '—'} | {it.get('phase','') or '—'} | "
                    f"{it.get('domain','') or '—'} | {bb} |")
    return "\n".join(rows)


def save(path, state):
    block = json.dumps(state, indent=2, ensure_ascii=False)
    body = (
        "# Implementation Tracker\n\n"
        "> IDC v2 filesystem tracker. The JSON block below is the state of record; the\n"
        "> board table is re-rendered from it. Edit through `scripts/idc_tracker_fs.py`.\n\n"
        f"{BEGIN}\n```json\n{block}\n```\n{END}\n\n"
        "## Board\n\n"
        f"{render_table(state)}\n"
    )
    # atomic write: same-dir temp + fsync + os.replace (mirrors scripts/idc_settings_json.py)
    parent = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".tracker-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = ""
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def op_init(path, args):
    if os.path.exists(path):
        # idempotent: leave an existing tracker untouched
        load(path)
        return
    save(path, empty_state())


def op_create(path, args):
    state = load(path, allow_missing=True)
    if args.status not in STATUSES:
        die(f"invalid status '{args.status}' (one of {STATUSES})")
    if args.stage and args.stage not in STAGES:
        die(f"invalid stage '{args.stage}' (one of {STAGES})")
    num = state["next_number"]
    blocked_by = [int(x) for x in args.blocked_by.split(",")] if args.blocked_by else []
    # An optional initial --comment lands in the SAME atomic save as the issue, so a caller that needs
    # a marker on the new item (e.g. the transition engine's recirculate-intake dedupe marker) never
    # has a create-then-comment window that could strand an unmarked item.
    state["issues"].append({
        "number": num, "title": args.title, "status": args.status,
        "stage": args.stage or "",
        "wave": args.wave or "", "phase": args.phase or "", "domain": args.domain or "",
        "blocked_by": blocked_by, "attempt": 0,
        "comments": [args.comment] if args.comment else [],
    })
    state["next_number"] = num + 1
    save(path, state)
    print(num)


def op_set(path, args):
    state = load(path)
    it = find(state, args.num)
    if args.field not in FIELDS:
        die(f"unknown field '{args.field}' (one of {FIELDS})")
    if args.field == "Status" and args.value not in STATUSES:
        die(f"invalid status '{args.value}' (one of {STATUSES})")
    if args.field == "Stage" and args.value not in STAGES:
        die(f"invalid stage '{args.value}' (one of {STAGES})")
    it[args.field.lower()] = args.value
    save(path, state)


def op_move(path, args):
    if args.status not in STATUSES:
        die(f"invalid status '{args.status}' (one of {STATUSES})")
    state = load(path)
    find(state, args.num)["status"] = args.status
    save(path, state)


def op_link(path, args):
    state = load(path)
    child = find(state, args.child)
    find(state, args.parent)  # validate parent exists
    if args.kind == "blocks":
        child.setdefault("blocked_by", [])
        if args.parent not in child["blocked_by"]:
            child["blocked_by"].append(args.parent)
    elif args.kind == "sub":
        child["parent"] = args.parent
    else:
        die("link --kind must be 'blocks' or 'sub'")
    save(path, state)


def op_query(path, args):
    state = load(path)
    out = []
    for it in sorted(state["issues"], key=lambda x: x["number"]):
        if args.status and it["status"] != args.status:
            continue
        if args.wave and it.get("wave") != args.wave:
            continue
        if args.phase and it.get("phase") != args.phase:
            continue
        if args.domain and it.get("domain") != args.domain:
            continue
        if args.stage:
            # Legacy 4-field board compatibility (WORKFLOW.md): an empty/missing Stage reads
            # as Buildable, so a pre-Stage Todo issue still surfaces under `--stage Buildable`.
            item_stage = it.get("stage") or "Buildable"
            if item_stage != args.stage:
                continue
        out.append(str(it["number"]))
    print("\n".join(out))


def op_comment(path, args):
    state = load(path)
    find(state, args.num).setdefault("comments", []).append(args.body)
    save(path, state)


def op_claim(path, args):
    state = load(path)
    it = find(state, args.num)
    it["status"] = "In Progress"
    it.setdefault("comments", []).append(f"claimed by {args.agent}")
    save(path, state)


def op_block(path, args):
    state = load(path)
    it = find(state, args.num)
    it["status"] = "Blocked"
    if args.by is not None:
        find(state, args.by)
        it.setdefault("blocked_by", [])
        if args.by not in it["blocked_by"]:
            it["blocked_by"].append(args.by)
    save(path, state)


def op_close(path, args):
    state = load(path)
    find(state, args.num)["status"] = "Done"  # idempotent
    save(path, state)


def op_show(path, args):
    state = load(path)
    it = find(state, args.num)
    if args.field:
        key = args.field.lower()
        print(it.get(key, ""))
    elif args.comments:
        print("\n".join(it.get("comments", [])))
    elif args.blocked_by:
        print("\n".join(str(n) for n in it.get("blocked_by", [])))
    else:
        print(json.dumps(it, indent=2, ensure_ascii=False))


# ── merge lease (single-holder serialization primitive) ──────────────────────
# The pi adapter's merge-serialization contract names "a single-holder merge lease, fail-closed
# (no lease -> no merge)". This is its filesystem-backend implementation: an atomic
# acquire-if-empty-or-expired returning an opaque token, release-by-token, and TTL expiry.
#
# Lease state lives in its OWN sidecar file (`<tracker>.leases.json`), NOT inside the TRACKER.md
# JSON blob. That isolation is load-bearing: ordinary tracker ops (create/comment/claim/...) do
# unlocked load-modify-save of TRACKER.md, so a writer that loaded a stale copy before a lease was
# acquired could otherwise save it back and erase a live lease. With a separate sidecar, no
# TRACKER.md write can touch the lease. Cross-process mutual exclusion for the lease read-modify-
# write comes from an advisory flock on `<tracker>.lock`.


@contextmanager
def tracker_lock(path):
    lock_path = path + ".lock"
    parent = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(parent, exist_ok=True)
    fh = open(lock_path, "w")  # noqa: SIM115 — held for the duration of the with-block
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        fh.close()


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def lease_sidecar(path):
    return path + ".leases.json"


def load_leases(path):
    sc = lease_sidecar(path)
    if not os.path.exists(sc):
        return {}  # MISSING == unheld (no lease has ever been written)
    # MALFORMED is NOT the same as missing (codex round-7): a truncated/merge-conflicted/hand-edited
    # lease sidecar is UNKNOWN lock state — treating it as "no lease" would let a second finisher
    # acquire while a holder may still be active. Fail closed: surface the corruption, don't grant.
    try:
        with open(sc, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        die(f"lease sidecar {sc} is unreadable/corrupt ({e}) — fail-closed; repair or remove it")
    if not isinstance(data, dict):
        die(f"lease sidecar {sc} is malformed (not a JSON object) — fail-closed")
    return data


def save_leases(path, leases):
    sc = lease_sidecar(path)
    parent = os.path.dirname(os.path.abspath(sc)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".leases-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(leases, indent=2, ensure_ascii=False))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, sc)
        tmp = ""
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def op_lease_acquire(path, args):
    if args.ttl <= 0:
        die("lease --ttl must be a positive number of seconds")
    with tracker_lock(path):
        leases = load_leases(path)
        now = time.time()
        cur = leases.get(args.lease)
        if cur and float(cur.get("expires_at_epoch", 0)) > now:
            # Held and unexpired -> fail-closed: never hand out a second concurrent holder.
            die(f"lease '{args.lease}' held by {cur.get('owner')!r} until {cur.get('expires_at')} "
                f"(no lease -> no merge)")
        token = uuid.uuid4().hex
        exp = now + args.ttl
        leases[args.lease] = {
            "owner": args.owner,
            "token": token,
            "acquired_at": iso(now),
            "expires_at": iso(exp),
            "expires_at_epoch": exp,
        }
        save_leases(path, leases)
    print(token)


def op_lease_release(path, args):
    with tracker_lock(path):
        leases = load_leases(path)
        cur = leases.get(args.lease)
        if not cur:
            return  # idempotent: nothing to release
        if cur.get("token") != args.token:
            die(f"lease '{args.lease}' release rejected — token mismatch "
                f"(held by {cur.get('owner')!r})")
        del leases[args.lease]
        save_leases(path, leases)


def op_lease_show(path, args):
    cur = load_leases(path).get(args.lease)
    if not cur:
        return  # unheld -> empty output
    out = {k: v for k, v in cur.items() if k != "token"}
    out["held"] = float(cur.get("expires_at_epoch", 0)) > time.time()
    print(json.dumps(out, indent=2, ensure_ascii=False))


def main():
    p = argparse.ArgumentParser(description="IDC v2 filesystem tracker backend")
    p.add_argument("--tracker", required=True, help="path to TRACKER.md")
    sub = p.add_subparsers(dest="op", required=True)

    sub.add_parser("init")

    c = sub.add_parser("create")
    c.add_argument("--title", required=True)
    c.add_argument("--status", default="Todo")
    c.add_argument("--stage", default="")
    c.add_argument("--wave", default="")
    c.add_argument("--phase", default="")
    c.add_argument("--domain", default="")
    c.add_argument("--blocked-by", dest="blocked_by", default="")
    c.add_argument("--comment", default="", help="an initial comment stored atomically with the new issue")

    s = sub.add_parser("set")
    s.add_argument("--num", type=int, required=True)
    s.add_argument("--field", required=True)
    s.add_argument("--value", required=True)

    m = sub.add_parser("move")
    m.add_argument("--num", type=int, required=True)
    m.add_argument("--status", required=True)

    lk = sub.add_parser("link")
    lk.add_argument("--parent", type=int, required=True)
    lk.add_argument("--child", type=int, required=True)
    lk.add_argument("--kind", default="blocks")

    q = sub.add_parser("query")
    q.add_argument("--status")
    q.add_argument("--stage")
    q.add_argument("--wave")
    q.add_argument("--phase")
    q.add_argument("--domain")

    cm = sub.add_parser("comment")
    cm.add_argument("--num", type=int, required=True)
    cm.add_argument("--body", required=True)

    cl = sub.add_parser("claim")
    cl.add_argument("--num", type=int, required=True)
    cl.add_argument("--agent", required=True)

    bl = sub.add_parser("block")
    bl.add_argument("--num", type=int, required=True)
    bl.add_argument("--by", type=int)

    cls = sub.add_parser("close")
    cls.add_argument("--num", type=int, required=True)

    sh = sub.add_parser("show")
    sh.add_argument("--num", type=int, required=True)
    sh.add_argument("--field")
    sh.add_argument("--comments", action="store_true")
    sh.add_argument("--blocked-by", dest="blocked_by", action="store_true")

    la = sub.add_parser("lease-acquire")
    la.add_argument("--lease", default="merge")
    la.add_argument("--owner", required=True)
    la.add_argument("--ttl", type=float, default=900.0, help="lease lifetime in seconds")

    lr = sub.add_parser("lease-release")
    lr.add_argument("--lease", default="merge")
    lr.add_argument("--token", required=True)

    lsw = sub.add_parser("lease-show")
    lsw.add_argument("--lease", default="merge")

    args = p.parse_args()
    ops = {
        "init": op_init, "create": op_create, "set": op_set, "move": op_move,
        "link": op_link, "query": op_query, "comment": op_comment, "claim": op_claim,
        "block": op_block, "close": op_close, "show": op_show,
        "lease-acquire": op_lease_acquire, "lease-release": op_lease_release,
        "lease-show": op_lease_show,
    }
    ops[args.op](args.tracker, args)


if __name__ == "__main__":
    main()
