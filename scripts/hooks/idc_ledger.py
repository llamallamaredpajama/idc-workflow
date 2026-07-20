#!/usr/bin/env python3
"""idc_ledger.py — the per-session obligations ledger (v4 Phase 3, plan §3.4).

WHAT THIS IS. A tiny, dependency-free state store that DETERMINISTIC hooks/scripts — **never the
LLM** — use to record and clear *obligation taints* accrued during a session, so later gates
(Phase 3's Stop / SubagentStop) can ask "does this session still owe work?" WITHOUT a board scan.
It is the file-backed-labels half of Omnigent's stateful-policy pattern; the gates are the policy.

THE FILE. One JSON file, `.idc-session-state.json`, at the **governed workspace root**
(`ledger_path(cwd)`). It is transient working state, gitignored via the scaffold
(`ensure_gitignored()`, wired into idc_init_scaffold.sh + /idc:update) so a clean autorun/build exit
never leaves committed litter. PRIMARY FORMAT — v2 (Task 2, command integrity), carrying BOTH the v1
`taints` array AND a `commands` array (the universal IDC command lifecycle envelope):

    {
      "version": 2,
      "taints":  [ {"kind": ..., "key": ..., "session_id": ..., "fields": {...}}, ... ],
      "commands": [
        {
          "session_id":   "S1",              # the session that owns this command obligation
          "command":      "think",           # one of idc_command_contract.COMMANDS
          "state":        "active",          # "active" (open) → "finished" (closed)
          "plugin_version": "4.1.0",         # the running plugin version that opened the record
          "args_sha256":  "<64-lowercase-hex>",  # digest of the raw arg text (never the text itself)
          "source":       "user",            # command_source (user | plugin | ...)
          "closeout":     null               # null while active; the validated terminal envelope once finished
        }
      ]
    }

BACKWARD COMPATIBILITY. A v1 file — `{"version": 1, "taints": [...]}` with no `commands` — is read
tolerantly and normalized to the v2 shape on read (see `read_state`); it is only rewritten with
`version: 2` on the next write. Every write preserves BOTH arrays: a taint write never drops
`commands`, and a command write never drops `taints`. The finished-command history is capped
(`_MAX_FINISHED`, newest-finish order) while an active record is NEVER pruned.

TAINT KINDS (at minimum; a taint's identity is the (kind, key) pair):
  - `unfiled_findings`         — reviewer nits/deferrals not yet routed to the board (drop A/B).
  - `mid_finish:<item>`        — the finish tail STARTED closing <item> but has not completed it.
  - `recirc_checkpoint:<ticket>` — the recirculator checkpointed <ticket> mid-drain (drop F).
A taint is set when the deterministic action STARTS and cleared **only when that action COMPLETES**
— never by an LLM, never speculatively.

INVARIANT #1 — A STALE LEDGER MUST NEVER FALSELY BLOCK A CLEAN BOARD. The ledger is a *hint*; the
board + `idc_autorun_drain.py` (`recirc_inbox:` / `unplanned_considerations:` counts + the `drain:`
verdict + its exit code) are GROUND TRUTH. Two independent defenses enforce this, and a consumer
(the Stop gate) MUST rely on the second:
  1. Session scoping. Every taint carries the `session_id` that created it. `pending_taints(cwd,
     session_id=X)` returns only the obligations session X is responsible for — taints created by X,
     plus unattributed (session_id=None) ones. A DEAD prior session's leftover taint (a crash
     mid-finish that never cleared) is that session's business, not X's, so it is not X's obligation
     and cannot block X. (The unscoped `pending_taints(cwd)` returns the full hint set — for
     cross-session recovery/inspection by Stage C, not for gating a stop.)
  2. Ground-truth cross-check. Even for a taint scoped to the CURRENT session, the Stop gate blocks
     only when the ledger hint AND the board/drain agree work remains. The ledger alone never
     blocks; a clean `drain: complete` (exit 0) wins over any stale taint.

FAIL MODES. Reads are TOLERANT: a missing or corrupt ledger reads as EMPTY and never throws — a
corrupt ledger must not brick a gate (`read_taints` / `pending_taints`). Writes are ATOMIC
(temp-file + os.replace, so a concurrent reader never sees a half-written file), SERIALIZED across
concurrent writers by an advisory lock (`_write_lock`) so no taint is lost to a read-modify-write
race, and BEST-EFFORT: a write (or a lock) that fails warns/degrades rather than raising, so
recording a taint can never break the user's command (a post-hoc observer never fails-closed). Writes are REPO-GATED — a no-op
outside an IDC-governed repo (reuse `idc_hook_lib.is_governed_repo`) so a non-IDC repo on the
machine is never littered with a state file.

IDC_HOOKS_OBSERVE_ONLY. Honored at the GATE layer (the Stop/SubagentStop gate downgrades block→warn
via idc_hook_lib), NOT here: the ledger deliberately keeps RECORDING taints under observe-only,
because the whole point of the observe-first rollout is to SEE which obligations would have accrued.
Suppressing the record would blind the very observation observe-only exists to collect.

DRAIN IS ALREADY TRUTHFUL — no change needed here (deliverable #3, confirmed by evidence). Stage B's
Stop gate reads `idc_autorun_drain.py`'s EXISTING line output — it always prints `recirc_inbox: N`,
`unplanned_considerations: M`, and `drain: <verdict>`, and exits with a distinct code
(0 complete/continue · 2 unknown · 3 rate-limited · 4 recirc-pending) — plus this ledger's
`mid_finish` / `unfiled_findings` taints. That is a single drain call autorun already makes: NO new
board GraphQL, and NO `--json` mode is required (the line format is stable and pinned by
tests/smoke/governance/drain-recirc-pending.sh). The fixpoint math + exit-code contract (Phase 0)
are untouched.

USAGE (import — the primary path, for hooks/scripts):
    import idc_ledger
    idc_ledger.set_taint(cwd, "mid_finish", key=str(issue), session_id=sid)
    ...                                        # do the deterministic close
    idc_ledger.clear_taint(cwd, "mid_finish", key=str(issue))
    for t in idc_ledger.pending_taints(cwd, session_id=sid): ...

USAGE (CLI — for the scaffold's gitignore step, and the governance test):
    python3 idc_ledger.py --cwd <repo> path
    python3 idc_ledger.py --cwd <repo> set   --kind mid_finish --key 42 --session S1 [--field k=v]
    python3 idc_ledger.py --cwd <repo> clear --kind mid_finish --key 42
    python3 idc_ledger.py --cwd <repo> pending [--session S1]   # one `kind` or `kind:key` per line
    python3 idc_ledger.py --cwd <repo> ensure-gitignore         # additive, idempotent
"""
import argparse
import contextlib
import json
import os
import sys
import tempfile

# Same-dir import: idc_ledger lives beside idc_hook_lib in scripts/hooks/, so when run as a script
# (sys.path[0] == this dir) or imported by a hook that put this dir on sys.path, this resolves.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, defined once, shared)

LEDGER_FILENAME = ".idc-session-state.json"
# The scaffold ignores the state file AND its sidecar write-lock (`.idc-session-state.json.lock`)
# with ONE glob line — in gitignore `*` matches the empty string, so it still ignores the file itself.
GITIGNORE_LINE = LEDGER_FILENAME + "*"
# v2 (Task 2 — command integrity): the state file now carries a `commands` array (the universal IDC
# command lifecycle envelope) ALONGSIDE the v1 `taints`. v1 files are read tolerantly and normalized
# to v2 on read (see read_state); a v1 file is only rewritten with `version: 2` when the next write
# happens. Every write preserves BOTH arrays — a taint write never drops commands, and vice versa.
_LEDGER_VERSION = 2
# Command lifecycle record states + the finished-history cap (never prunes an active record).
_CMD_ACTIVE = "active"
_CMD_FINISHED = "finished"
_MAX_FINISHED = 20

try:
    import fcntl  # POSIX advisory file locks (macOS/Linux — IDC's platforms)
except ImportError:  # pragma: no cover - non-POSIX fallback
    fcntl = None


@contextlib.contextmanager
def _write_lock(cwd):
    """Serialize the ledger's read-modify-write across concurrent hook/script processes.

    set_taint/clear_taint READ the whole ledger, MODIFY it, then atomically REPLACE the file. Two
    processes recording DIFFERENT taints at the same time would each read the same old snapshot and
    the last os.replace would win — silently dropping the other's taint. A dropped taint is a dropped
    obligation, exactly the "loop lies about being done" failure Phase 3 exists to prevent. An
    exclusive advisory lock on a STABLE sidecar `.idc-session-state.json.lock` (we lock a sidecar,
    not the ledger itself, because os.replace orphans a lock held on the renamed inode) makes the
    read-modify-write atomic with respect to other writers.

    BEST-EFFORT (a post-hoc observer must never fail-closed): if fcntl is unavailable or the lock
    cannot be taken, proceed UNLOCKED rather than break the caller's command."""
    if fcntl is None:
        yield
        return
    fh = None
    try:
        fh = open(ledger_path(cwd) + ".lock", "w", encoding="utf-8")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    except OSError:
        if fh is not None:
            try:
                fh.close()
            except OSError:
                pass
            fh = None
    try:
        yield
    finally:
        if fh is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                fh.close()
            except OSError:
                pass


# ── paths ──────────────────────────────────────────────────────────────────────────────────────────
def ledger_path(cwd):
    """The `.idc-session-state.json` path at the governed workspace root `cwd`."""
    return os.path.join(cwd or ".", LEDGER_FILENAME)


# ── tolerant read ────────────────────────────────────────────────────────────────────────────────
def _read_raw(cwd):
    """The raw ledger dict (both `taints` and `commands`). TOLERANT: a missing or corrupt ledger
    reads as an EMPTY dict and NEVER throws — a corrupt ledger must not brick a gate. The ONE decode
    point both the v1 taint readers and the v2 command readers share, so tolerance is defined once."""
    try:
        with open(ledger_path(cwd), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


# THE IDENTITY EVERY ENTRY MUST CARRY TO BE SEEN AT ALL — defined once, because the tolerant readers
# and the strict probe are two views of ONE predicate and had drifted apart. The readers below SKIP an
# entry missing these fields; `probe` therefore has to REJECT a ledger containing one, or a real
# obligation that lost its `kind` (a hand-edited file) is invisible to the readers and pronounced
# trustworthy by the probe — which is exactly the hidden-obligation false-clean the probe exists to
# catch, arriving through the probe itself.
_TAINT_IDENTITY = ("kind",)
_COMMAND_IDENTITY = ("session_id", "command")


def _has_identity(entry, fields):
    return isinstance(entry, dict) and all(entry.get(f) for f in fields)


def read_taints(cwd, _raw=None):
    """Every taint dict currently in the ledger (a list). TOLERANT: a missing or corrupt ledger
    reads as an EMPTY list and NEVER throws — a corrupt ledger must not brick a gate. `_raw` lets a
    mutator that already decoded the file under its lock reuse that one read."""
    taints = (_read_raw(cwd) if _raw is None else _raw).get("taints", [])
    if not isinstance(taints, list):
        return []
    return [t for t in taints if _has_identity(t, _TAINT_IDENTITY)]


def _read_commands(cwd, _raw=None):
    """Every well-formed command lifecycle record currently in the ledger (a list). TOLERANT: a
    missing/corrupt ledger — or a v1 file with no `commands` key — reads as EMPTY, never throws. A
    record is well-formed iff it carries a session_id and a command (the identity a gate keys on).
    `_raw` lets a mutator that already decoded the file under its lock reuse that one read."""
    cmds = (_read_raw(cwd) if _raw is None else _raw).get("commands", [])
    if not isinstance(cmds, list):
        return []
    return [c for c in cmds if _has_identity(c, _COMMAND_IDENTITY)]


def read_state(cwd):
    """The whole ledger as a normalized v2 dict: {'version': 2, 'taints': [...], 'commands': [...]}.
    TOLERANT. A v1 file (`{'version': 1, 'taints': [...]}`) is normalized in-memory to v2 with an
    empty `commands` list — it is NOT rewritten on disk until the next write, so a read never mutates
    the file."""
    return {"version": _LEDGER_VERSION, "taints": read_taints(cwd), "commands": _read_commands(cwd)}


def probe(cwd):
    """`(ok, detail)` — can this ledger's contents be TRUSTED as a complete account?

    THE ONE STRICT READER, and why it has to exist next to the tolerant ones. Every reader above is
    deliberately tolerant: a corrupt ledger reads as empty so a damaged file can never brick a gate.
    That is right for a HINT (`pending_taints` scoping a block) and wrong for a PROOF. `/idc:pause`
    asks "is anything half-done?" and reports `pause-ready: ok` on an empty answer — so against an
    unreadable ledger the tolerant read turns "I cannot tell" into "nothing is wrong", and the pause
    certificate is written over a hidden `mid_finish` obligation. That is the exact false-green this
    codebase refuses everywhere else.

    So callers that CERTIFY something ask here first, and treat a False as INDETERMINATE rather than
    clean. A ledger that is absent is honestly empty (nothing has ever been recorded) and is `ok`;
    only a file that EXISTS and cannot be parsed into the expected shape is untrustworthy.
    """
    path = ledger_path(cwd)
    if not os.path.exists(path):
        return True, "no ledger yet"
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as e:
        return False, f"the obligations ledger {path} could not be read ({e})"
    except ValueError as e:
        return False, f"the obligations ledger {path} is not valid JSON ({e})"
    if not isinstance(data, dict):
        return False, (f"the obligations ledger {path} is a {type(data).__name__}, not an object — "
                       f"its contents cannot be trusted")
    for field, identity in (("taints", _TAINT_IDENTITY), ("commands", _COMMAND_IDENTITY)):
        val = data.get(field)
        if val is not None and not isinstance(val, list):
            return False, (f"the obligations ledger {path} has a non-list `{field}` "
                           f"({type(val).__name__}) — its contents cannot be trusted")
        for entry in (val or []):
            if not isinstance(entry, dict):
                return False, (f"the obligations ledger {path} has a non-object entry in `{field}` "
                               f"({type(entry).__name__}) — the tolerant readers SKIP such entries, "
                               f"so a real obligation could be hiding behind one")
            # ...and the SAME question for the shape the readers actually key on. Rejecting only
            # non-dicts asked the wrong question: the tolerant readers skip on a MISSING IDENTITY
            # FIELD, not on non-dict-ness, so a `mid_finish` entry that had lost its `kind` was
            # skipped by every reader and certified readable here — a half-done obligation hidden
            # behind a probe that said the ledger could be trusted.
            missing = [f for f in identity if not entry.get(f)]
            if missing:
                return False, (f"the obligations ledger {path} has an entry in `{field}` with no "
                               f"{', '.join(missing)} — the tolerant readers SKIP such entries, so a "
                               f"real obligation could be hiding behind one")
    return True, "readable"


def pending_taints(cwd, session_id=None):
    """The pending taints (invariant #1 scoping).

    session_id=None → the FULL hint set (every taint) — cross-session recovery/inspection, NOT a
    gate signal. session_id=X → only the obligations session X is responsible for: taints created
    by X plus unattributed (session_id=None) ones, so a dead prior session's leftover taint is never
    X's obligation and cannot falsely block X's clean board."""
    taints = read_taints(cwd)
    if session_id is None:
        return taints
    return [t for t in taints if t.get("session_id") in (session_id, None)]


# ── atomic, best-effort write ────────────────────────────────────────────────────────────────────
def _atomic_write_state(cwd, taints, commands):
    """Write the WHOLE ledger (both arrays) atomically (temp-file + os.replace). BEST-EFFORT for the
    caller's control flow — an OSError WARNS and RETURNS (never raises), so recording state can never
    break the user's command — but the outcome is SURFACED as a bool: True iff the state actually
    PERSISTED to disk, False if the temp-file create / write / os.replace failed. A caller that reports
    a record as opened (the entry gate, command_start) MUST check this so a swallowed write is never
    mistaken for a persisted one (Fix 2). This is the single write door — every taint write AND every
    command write funnels through here, so neither array can ever silently drop the other (the v1→v2
    co-existence invariant)."""
    path = ledger_path(cwd)
    d = os.path.dirname(path) or "."
    payload = {"version": _LEDGER_VERSION, "commands": commands, "taints": taints}
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".idc-ledger.", suffix=".tmp")
    except OSError as e:
        idc_hook_lib.warn(f"ledger: cannot create temp file in {d}: {e}")
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as e:
        idc_hook_lib.warn(f"ledger: atomic write to {path} failed: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False
    return True


# ── the write API (deterministic callers only) ──────────────────────────────────────────────────
def set_taint(cwd, kind, key=None, session_id=None, **fields):
    """Add or update the (kind, key) taint. REPO-GATED: a silent no-op outside a governed repo.
    Upserts by identity (kind, key) so a re-set never duplicates. Carries the creating session_id
    (invariant #1 scoping) and any extra `fields`. Recovers a corrupt/missing file (tolerant read
    → rewrite). The write preserves the `commands` array (the v1 taint writers' door).

    RETURNS whether the taint is now DURABLE — persisted to disk AND readable back. Still
    best-effort for control flow (it never raises), but the outcome is surfaced rather than
    discarded, because for some callers the taint IS the safety property: a `mid_finish` obligation
    is the only record that an irreversible merge is underway, so a caller about to take that step
    must be able to tell whether the record it is relying on actually exists. A caller that does not
    care can keep ignoring the result exactly as before.

    The READBACK is not paranoia about `os.replace`. `_atomic_write_state` returns True the moment
    the rename succeeds, which does not prove the bytes parse back into the taint just written — a
    full disk, a truncating filesystem or a racing writer all produce a "successful" write whose
    result is not there. Since the whole point is to survive a process that dies seconds later, the
    only useful question is whether a LATER, DIFFERENT reader would find it.
    """
    if not idc_hook_lib.is_governed_repo(cwd):
        return False
    key = None if key is None else str(key)
    if session_id is None:
        session_id = os.environ.get("IDC_SESSION_ID") or None
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost taints)
        raw = _read_raw(cwd)
        taints = [t for t in read_taints(cwd, _raw=raw) if not (t.get("kind") == kind and t.get("key") == key)]
        taints.append({"kind": kind, "key": key, "session_id": session_id, "fields": dict(fields)})
        if not _atomic_write_state(cwd, taints, _read_commands(cwd, _raw=raw)):
            return False
        return any(t.get("kind") == kind and t.get("key") == key for t in read_taints(cwd))


def clear_taint(cwd, kind, key=None):
    """Remove the (kind, key) taint — called ONLY when the deterministic action COMPLETES.
    REPO-GATED (no-op outside a governed repo). Idempotent: clearing an absent taint is a no-op."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return
    key = None if key is None else str(key)
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost taints)
        raw = _read_raw(cwd)
        before = read_taints(cwd, _raw=raw)
        after = [t for t in before if not (t.get("kind") == kind and t.get("key") == key)]
        if len(after) != len(before):
            _atomic_write_state(cwd, after, _read_commands(cwd, _raw=raw))


# ── the command lifecycle envelope (v2 — Task 2, command integrity) ───────────────────────────────
# A `commands[]` record is the durable obligation that a governed `/idc:*` command was ENTERED and
# must be CLOSED with a valid terminal status. Its identity is the (session_id, command) pair. The
# deterministic entry gate opens it (command_start); the deterministic command tail closes it
# (command_finish); the Stop closeout gate reads active_commands to refuse an un-closed command.
def _prune_finished(commands):
    """Cap the finished-record history at `_MAX_FINISHED`, newest write order, NEVER pruning an
    active record. Active records are always retained in place; only the OLDEST finished records past
    the cap are dropped."""
    active = [c for c in commands if c.get("state") == _CMD_ACTIVE]
    finished = [c for c in commands if c.get("state") != _CMD_ACTIVE]
    if len(finished) > _MAX_FINISHED:
        finished = finished[-_MAX_FINISHED:]
    return active + finished


def _union_str_list(old, new):
    """Order-preserving, de-duplicated UNION of two string lists (round-5 finding 1, rule A —
    monotonic obligations). Prior obligations come first so a re-start can only ADD to the stamped
    set, never reorder-away or narrow it. Non-list inputs are treated as empty."""
    out = []
    for value in list(old if isinstance(old, list) else []) + list(new if isinstance(new, list) else []):
        s = str(value)
        if s not in out:
            out.append(s)
    return out


class ObligationConflict(Exception):
    """A `command_start` that would REPLACE (not just union) a stamped obligation on the active
    (session, command) record is refused (round-6 BLOCKS 1, rule A). Raised for a Think re-start that
    binds a DIFFERENT intake manifest than the one already stamped: the first manifest's exact-once
    coverage obligation cannot silently vanish under a narrowing/replacing restart. The prior record is
    left intact (nothing is persisted); the caller surfaces an honest refusal instead of opening a
    record whose obligation dropped the first manifest's units."""

    def __init__(self, command, prior, incoming):
        self.command = command
        self.prior = prior
        self.incoming = incoming
        super().__init__(
            f"/idc:{command} re-start binds a different intake manifest ({incoming!r}) than the one "
            f"already stamped on the active record ({prior!r}); a restart may only ADD to a stamped "
            "obligation, never replace it — finish or reset the active run before intaking a different "
            "manifest, so the first manifest's coverage obligation cannot vanish")


def command_start(cwd, session_id, command, plugin_version, args_sha256, source,
                  intake_manifest=None, intake_units=None, recirc_requested=None,
                  build_requested=None, plan_admitted=None, uninstall_flags=None, nonce=None,
                  build_frontier=None, uninstall_receipt_source=None, uninstall_receipt_sha256=None):
    """Atomic UPSERT of the active command record by (session_id, command) — never duplicates an
    active record (a re-entry of the same command in the same session updates the one record in
    place). REPO-GATED: a silent no-op outside a governed repo (returns `{}`). Preserves the taint
    array. Returns the record dict ONLY when the write actually PERSISTED; returns None when the
    ledger write FAILED (Fix 2) — a caller must never report an obligation as opened on a failed
    write, or the Stop gate would try to enforce a closeout for a record that does not exist.

    An EMPTY/blank session identity is REFUSED fail-closed (returns None, no write): a runtime that
    fires no Claude UserPromptExpansion (Codex/Pi) can leave `$CLAUDE_CODE_SESSION_ID` empty, and an
    anonymous record keyed on session="" would let two session-less runs collide on (session="",
    command) — finishing or overwriting each other's obligation. The identity is load-bearing, so a
    blank one is never stored (finding 5)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return {}
    if not str(session_id).strip():
        return None
    session_id = str(session_id)
    command = str(command)
    rec = {
        "session_id": session_id,
        "command": command,
        "state": _CMD_ACTIVE,
        "plugin_version": plugin_version or "",
        "args_sha256": args_sha256 or "",
        "source": source or "",
        "closeout": None,
    }
    # Durable intake-mode marker (finding 2): a Think run started with `--doc/--unit` records its
    # intake manifest (repo-relative) + selected units on the record, so the Think closeout re-verifies
    # exact-once coverage from the RECORD — never inferable only from caller-supplied finish input.
    if intake_manifest:
        rec["intake_manifest"] = str(intake_manifest)
        rec["intake_units"] = [str(u) for u in (intake_units or [])]
    # Durable recirculate requested-set marker (wave-3 finding 4): a /idc:recirculate run started with
    # a named `<manifest>#<unit>` (or a bare `#<ticket>`) records the requested item(s) on the record,
    # so the recirculate closeout re-verifies that EVERY requested item got a validated, tracker-checked
    # disposition — never inferable only from caller-supplied finish input. A bare full-inbox drain
    # (`/idc:recirculate` with no named item) records an empty requested set.
    if recirc_requested:
        rec["recirc_requested"] = [str(r) for r in recirc_requested]
    # Durable rule-A obligation markers stamped at command START, re-derived at finish (wave-4). A
    # Build run records its requested issue set; a Plan run records the admitted-consideration set it
    # was started against (so a consideration the command itself retires stays in the required set); an
    # Uninstall run records the requested opt-in flags (--close-issues / --delete-board). The finish
    # validator compares against the STAMPED set + live reads, never caller-supplied keys.
    if build_requested:
        rec["build_requested"] = [str(b) for b in build_requested]
    # Durable whole-frontier marker (round-5 finding 4): a Build run with NO explicit issue set records
    # the eligible-frontier issue set it was started against, so `complete` requires a merged-PR receipt
    # per stamped-frontier issue OR an oracle-confirmed empty remaining frontier. `[]` (a readable but
    # empty frontier at start) is stamped too — distinct from None (frontier never read).
    if build_frontier is not None:
        rec["build_frontier"] = [str(b) for b in build_frontier]
    if plan_admitted is not None:
        rec["plan_admitted"] = [str(p) for p in plan_admitted]
    if uninstall_flags:
        rec["uninstall_flags"] = sorted({str(f) for f in uninstall_flags})
    if uninstall_receipt_source:
        rec["uninstall_receipt_source"] = str(uninstall_receipt_source)
    if uninstall_receipt_sha256:
        rec["uninstall_receipt_sha256"] = str(uninstall_receipt_sha256)
    # A per-record nonce binds a diagnostic report (doctor/janitor) to THIS command invocation
    # (wave-4 finding 7): the helper that RUNS the scan writes the report carrying this nonce, and the
    # closeout requires the report's nonce to MATCH the active record's — so a stale/foreign report
    # cannot back a new run.
    if nonce:
        rec["nonce"] = str(nonce)
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost records)
        raw = _read_raw(cwd)
        commands = _read_commands(cwd, _raw=raw)
        replaced = False
        for i, c in enumerate(commands):
            if (c.get("session_id") == session_id and c.get("command") == command
                    and c.get("state") == _CMD_ACTIVE):
                # MONOTONIC OBLIGATIONS (round-5 finding 1, rule A). A re-start of the SAME
                # (session, command) may only UNION each stamped obligation with the prior record —
                # NEVER replace or narrow it. So `/build #1 #2` re-entered as `/build #1` still owes
                # BOTH, an uninstall two-flag run re-entered with one flag still owes BOTH, and an
                # intake-mode Think re-entered with fewer units still owes every prior unit. (Wave-4
                # only carried a marker forward when the re-start supplied NONE; a non-empty smaller
                # value silently shed the difference — the exact regression this closes.)
                # Intake manifest: keep the prior manifest whenever this re-start binds none OR the
                # SAME manifest (union its units). A re-start that binds a DIFFERENT manifest is
                # REFUSED (round-6 BLOCKS 1, rule A): silently replacing it would drop the first
                # manifest's exact-once coverage obligation, letting a closeout succeed while the first
                # manifest's units never got a durable disposition. Raise BEFORE any state is persisted
                # so the prior obligation record is left fully intact.
                prior_manifest = c.get("intake_manifest")
                if prior_manifest and intake_manifest and str(intake_manifest) != prior_manifest:
                    raise ObligationConflict(command, prior_manifest, str(intake_manifest))
                if prior_manifest and (not intake_manifest or str(intake_manifest) == prior_manifest):
                    rec["intake_manifest"] = prior_manifest
                    rec["intake_units"] = _union_str_list(c.get("intake_units"),
                                                          rec.get("intake_units"))
                # Recirculate requested set, Build requested set, Uninstall flags: union with the prior.
                unioned_recirc = _union_str_list(c.get("recirc_requested"), recirc_requested)
                if unioned_recirc:
                    rec["recirc_requested"] = unioned_recirc
                unioned_build = _union_str_list(c.get("build_requested"), build_requested)
                if unioned_build:
                    rec["build_requested"] = unioned_build
                # Build whole-frontier set: union the prior stamp with this re-start's live read (a
                # frontier issue built between restarts stays in the required coverage set).
                prior_frontier = c.get("build_frontier")
                if prior_frontier is not None or build_frontier is not None:
                    rec["build_frontier"] = _union_str_list(prior_frontier, build_frontier)
                unioned_flags = _union_str_list(c.get("uninstall_flags"), uninstall_flags)
                if unioned_flags:
                    rec["uninstall_flags"] = sorted(set(unioned_flags))
                # Receipt source is monotonic too. Once any start observed the canonical modern
                # receipt, deleting it before finish cannot downgrade this run to the legacy list.
                prior_receipt = c.get("uninstall_receipt_source")
                if prior_receipt:
                    rec["uninstall_receipt_source"] = prior_receipt
                elif uninstall_receipt_source:
                    rec["uninstall_receipt_source"] = str(uninstall_receipt_source)
                # Keep the FIRST modern receipt digest across re-entry. A changed receipt is an
                # integrity conflict for finish, not a new manifest that may replace the obligation.
                prior_receipt_sha = c.get("uninstall_receipt_sha256")
                if prior_receipt_sha:
                    rec["uninstall_receipt_sha256"] = prior_receipt_sha
                elif uninstall_receipt_sha256:
                    rec["uninstall_receipt_sha256"] = str(uninstall_receipt_sha256)
                # Plan admitted set: union the prior stamp with this re-start's live read (a
                # consideration the plan itself retires between restarts stays in the required set).
                prior_admitted = c.get("plan_admitted")
                if prior_admitted is not None or plan_admitted is not None:
                    rec["plan_admitted"] = _union_str_list(prior_admitted, plan_admitted)
                # Nonce is per-record identity, not an obligation set: keep the prior one when this
                # re-start supplied none, so a diagnostic report stays bound to the same record.
                if not nonce and c.get("nonce"):
                    rec["nonce"] = c.get("nonce")
                commands[i] = rec
                replaced = True
                break
        if not replaced:
            commands.append(rec)
        persisted = _atomic_write_state(cwd, read_taints(cwd, _raw=raw), _prune_finished(commands))
    return rec if persisted else None


def command_finish(cwd, session_id, command, status, evidence):
    """Finish ONLY an existing ACTIVE record owned by `session_id` — a foreign session cannot finish
    or inherit another session's record, and a missing active record is a no-op. Records the terminal
    `status` + normalized `evidence` in the record's `closeout` and flips its state to finished.
    REPO-GATED (no-op outside a governed repo). Returns the finished record dict, or None when there
    was no matching active record owned by this session OR the closeout write did not PERSIST (Fix 2)
    — either way the caller surfaces the non-close as a failure rather than reporting a false close.

    An EMPTY/blank session identity is REFUSED fail-closed (returns None): a session="" finish could
    otherwise close another anonymous session's record (finding 5)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return None
    if not str(session_id).strip():
        return None
    session_id = str(session_id)
    command = str(command)
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers
        raw = _read_raw(cwd)
        commands = _read_commands(cwd, _raw=raw)
        target = None
        for c in commands:
            if (c.get("session_id") == session_id and c.get("command") == command
                    and c.get("state") == _CMD_ACTIVE):
                target = c
                break
        if target is None:
            return None
        target["state"] = _CMD_FINISHED
        target["closeout"] = {"status": status, "evidence": evidence}
        # Move the just-finished record to the NEWEST write position so the finished-history cap
        # (_prune_finished keeps the last _MAX_FINISHED in write order) drops the OLDEST finished
        # record — never this one. Finishing in place would leave an early-started record at the
        # front of the list, where the cap would prune it as the "oldest" even though it just closed.
        commands.remove(target)
        commands.append(target)
        if not _atomic_write_state(cwd, read_taints(cwd, _raw=raw), _prune_finished(commands)):
            return None  # the close did not persist → do not report a false close (Fix 2)
    return target


def active_commands(cwd, session_id=None):
    """The state=active command records, optionally scoped to one session. TOLERANT (a corrupt/missing
    ledger reads as empty). session_id=None → every active record; session_id=X → only X's active
    records, so the Stop closeout gate never traps an unrelated session with another's open command."""
    active = [c for c in _read_commands(cwd) if c.get("state") == _CMD_ACTIVE]
    if session_id is None:
        return active
    return [c for c in active if c.get("session_id") == str(session_id)]


# ── the gitignore scaffold hook (idempotent, non-destructive) ────────────────────────────────────
def ensure_gitignored(repo_root):
    """Ensure the repo-root `.gitignore` contains `.idc-session-state.json`, idempotently and
    NON-DESTRUCTIVELY (create the file if absent; otherwise APPEND the line only if missing — never
    rewrite or reorder an operator's existing lines). REPO-GATED: a no-op outside a governed repo,
    so a stray call never creates a `.gitignore` in a non-IDC dir. Returns True iff the line is
    present afterward."""
    return idc_hook_lib.ensure_gitignored(
        repo_root, GITIGNORE_LINE, label="ledger",
        created_comment="# IDC obligations ledger — transient per-session state, never committed.",
        appended_comment="# IDC obligations ledger (per-session state; do not commit)")


# ── CLI (scaffold gitignore step + governance test driver; NOT an LLM-facing surface) ────────────
def _fmt(t):
    """One pending taint as a grep-friendly line: `kind` or `kind:key`."""
    return f"{t['kind']}:{t['key']}" if t.get("key") is not None else str(t["kind"])


def main(argv=None):
    ap = argparse.ArgumentParser(description="IDC per-session obligations ledger (scripts/hooks only)")
    ap.add_argument("--cwd", default=".", help="governed workspace root (default: cwd)")
    sub = ap.add_subparsers(dest="op", required=True)

    sub.add_parser("path", help="print the ledger file path")
    sub.add_parser("ensure-gitignore", help="idempotently add the ledger to the repo-root .gitignore")

    sp = sub.add_parser("set", help="add/update a taint")
    sp.add_argument("--kind", required=True)
    sp.add_argument("--key", default=None)
    sp.add_argument("--session", default=None)
    sp.add_argument("--field", action="append", default=[], metavar="k=v",
                    help="extra field (repeatable)")

    cp = sub.add_parser("clear", help="remove a taint (deterministic action completed)")
    cp.add_argument("--kind", required=True)
    cp.add_argument("--key", default=None)

    pp = sub.add_parser("pending", help="list pending taints (one `kind` or `kind:key` per line)")
    pp.add_argument("--session", default=None, help="scope to this session (invariant #1)")

    args = ap.parse_args(argv)
    cwd = args.cwd

    if args.op == "path":
        print(ledger_path(cwd))
    elif args.op == "ensure-gitignore":
        ensure_gitignored(cwd)
    elif args.op == "set":
        fields = {}
        for kv in args.field:
            k, _, v = kv.partition("=")
            fields[k] = v
        set_taint(cwd, args.kind, key=args.key, session_id=args.session, **fields)
    elif args.op == "clear":
        clear_taint(cwd, args.kind, key=args.key)
    elif args.op == "pending":
        for t in pending_taints(cwd, session_id=args.session):
            print(_fmt(t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
