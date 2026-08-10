#!/usr/bin/env python3
"""Shared IDC Path Gate core.

One deterministic policy core for runtime/file/git mutation authorization. Adapters translate a tool
payload into a normalized request and this module returns allow/deny plus remediation.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Any

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HOOKS_DIR = os.path.join(SCRIPT_DIR, "hooks")
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, HOOKS_DIR)

import idc_command_contract as C  # noqa: E402
import idc_credential_shapes as CS  # noqa: E402
import idc_ledger as L  # noqa: E402

AUTH_RELPATH = os.path.join("idc-path-gate", "authorization.json")
ADMISSION_LOCK_RELPATH = os.path.join("idc-path-gate", "admission.lock")
# The live-contract pointer: machine-owned state next to the authorization, written ONLY by
# `idc_validation_contract.freeze_contract` (fixed code) when a Build validation contract is frozen,
# and cleared when the claimed item reaches a terminal Status. It is how the minting side discovers
# "the frozen contract that scopes this repository's in-flight Build unit" (spec §3.3/§4.2) without
# trusting a caller-supplied path.
LIVE_CONTRACT_RELPATH = os.path.join("idc-path-gate", "live-contract.json")
PROTECTED_MACHINE_RULES = [
    "TRACKER.md",
    "TRACKER-archive.md",
    "docs/workflow/install-receipt.yaml",
    "docs/workflow/transition-journal.ndjson",
    "docs/workflow/transition-journal.ndjson.*",
    ".idc-session-state.json*",
    ".idc-drain-verdict.json*",
    ".idc-*-report.json*",
    ".idc-pause-state.json*",
    # The derived run-trace mirror db and its WAL/SHM sidecars (see docs/architecture.md). It is
    # gitignored, but an ignore rule is ADVISORY: `git add -f`, or a db already tracked from before
    # the rule existed, walks straight past it. Its rows hold the VERBATIM payloads of the receipt
    # sidecars listed above, whose own writers create them 0600 — so committing it would publish
    # exactly what those modes withhold, and its contract is "derived, disposable, never committed".
    # Hard-denied for the same reason as its peers: machine-owned state is never a hand-edited one.
    ".idc-trace-mirror.db*",
]
# The governance anchor: its presence in the worktree is what arms every IDC gate, `/idc:init` writes
# it, and `/idc:uninstall` removes it LAST (commands/uninstall.md Phase 3c). A commit that carries the
# repository ACROSS that boundary — its parent's tree has the anchor, its own tree does not — is THE
# ungoverning commit, and is the only shape the uninstall push door can ever admit (issue #201).
GOVERNANCE_ANCHOR_RELPATH = "docs/workflow/tracker-config.yaml"
# Machine-owned witness of the uninstall removal commits a sanctioned door admitted. Written ONLY by
# `idc_git_path_gate.py witness-uninstall` (fixed code) and only after that door re-derives the
# commit's shape from git. It lives UNDER THE COMMON GIT DIRECTORY (`uninstall_witness_path`) — not in
# the worktree, which uninstall is in the middle of emptying — so it survives the very removal it
# attests to, it never travels to a remote, and unlike the per-worktree authorization beside it every
# checkout of the repository reads the same one.
UNINSTALL_WITNESS_RELPATH = os.path.join("idc-path-gate", "uninstall-witness.json")
_OID_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
READ_ONLY_COMMANDS = {"doctor", "pause"}
DEFAULT_TTL_SECONDS = 4 * 60 * 60
PATHWAY_MODES = {"off", "controlled", "app-locked"}
# A config that is readable and explicitly declares a `mode:` value we do not recognize (a typo like
# `controllled`, or a blank value) is MALFORMED, not `off`. Collapsing it to `off` would silently
# disable enforcement on a config the operator believed was enforcing. The runtime fails closed on it
# (it is not `off`, so a would-be denial is NOT downgraded to observe) and `/idc:doctor` reports it as
# indeterminate — never an honest posture (F10).
UNKNOWN_MODE = "unknown"
# A readable config that explicitly DECLARES a `pathway_enforcement.attempt_ceiling` we cannot use (a
# non-integer, zero, or negative) is MALFORMED — distinct from ABSENT (no key at all). The caller warns
# the operator and falls back to the built-in default rather than silently swallowing the typo: the
# attempt_ceiling analogue of UNKNOWN_MODE (F23). A distinct sentinel object so it can never collide
# with a real ceiling value or with `None`.
MALFORMED_ATTEMPT_CEILING = object()

try:
    import fcntl  # POSIX advisory locks (macOS/Linux — IDC's supported platforms)
except ImportError:  # pragma: no cover - unsupported platform fails closed at acquisition
    fcntl = None


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _iso(ts: dt.datetime) -> str:
    return ts.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str) -> dt.datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except ValueError:
        return None


def _run_git(repo: str, *args: str) -> str:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(CS.scrub(proc.stderr or proc.stdout or "git failed").strip())
    return (proc.stdout or "").strip()


def repo_root(repo: str) -> str:
    return os.path.realpath(os.path.abspath(repo))


def _is_git_worktree(repo: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and (proc.stdout or "").strip() == "true"


# How a `pathway_enforcement` key was (or was not) declared — see `_pathway_block_value`.
PATHWAY_CONFIG_UNREADABLE = "unreadable"
PATHWAY_KEY_ABSENT = "absent"
PATHWAY_KEY_DECLARED = "declared"


def _pathway_block_value(repo: str, key: str) -> tuple[str, str | None]:
    """`(state, raw_value)` for `pathway_enforcement.<key>` in WORKFLOW-config.yaml, no YAML dependency.

    THE ONE block parse for that stanza — `pathway_mode` and `pathway_attempt_ceiling` both read it
    through here, so the two can no longer drift about what a config declares (they used to be
    duplicated line for line, with a comment asking future editors to keep them in step by hand).

    `state` is one of:
      * `PATHWAY_CONFIG_UNREADABLE` — the config is missing or could not be opened. Callers decide what
        an unanswerable question means for them; it is NOT the same fact as a declared value.
      * `PATHWAY_KEY_ABSENT` — the config IS readable but declares no such key (no
        `pathway_enforcement:` block at all, or a block without this key).
      * `PATHWAY_KEY_DECLARED` — the key is declared; `raw_value` is its value with surrounding quotes
        stripped (possibly the empty string, which is a malformed declaration, not an absence).
    """
    config_path = os.path.join(repo_root(repo), "WORKFLOW-config.yaml")
    try:
        with open(config_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return PATHWAY_CONFIG_UNREADABLE, None

    block_indent: int | None = None
    for raw_line in lines:
        content = raw_line.split("#", 1)[0].rstrip()
        if not content.strip():
            continue
        indent = len(content) - len(content.lstrip())
        stripped = content.strip()
        if block_indent is None:
            if stripped == "pathway_enforcement:":
                block_indent = indent
            continue
        if indent <= block_indent:
            break
        found_key, separator, raw_value = stripped.partition(":")
        if separator and found_key.strip() == key:
            return PATHWAY_KEY_DECLARED, raw_value.strip().strip("\"'")
    return PATHWAY_KEY_ABSENT, None


def pathway_mode_state(repo: str) -> str:
    """Whether this repo DECLARES `pathway_enforcement.mode` — one of the three PATHWAY_* states above.

    `pathway_mode()` deliberately answers `off` for all of "explicitly off", "declares no mode", and
    "I could not read your config", because the RUNTIME gate needs one fail-closed answer. That
    collapse is also how a fully-governed github repo ran with every denial downgraded to observe while
    the operator believed it was enforcing: an absent stanza was indistinguishable from a deliberate
    `mode: off`, and nothing anywhere said so. Diagnostics (`/idc:doctor` Row 4b, `/idc:update`'s
    pathway advisory) ask THIS instead, so "you never set a posture" can be reported as its own fact
    without weakening the runtime default."""
    state, _ = _pathway_block_value(repo, "mode")
    return state


def pathway_mode(repo: str) -> str:
    """Read the scaffolded pathway posture without taking a YAML dependency.

    Returns one of PATHWAY_MODES, or `UNKNOWN_MODE` when the config IS readable and explicitly declares
    a `mode:` whose value is not a recognized mode (a typo / malformed value). A config that is missing,
    unreadable, or declares no `mode:` returns `off` (an ungoverned or non-enforcing repo). The
    distinction is load-bearing: `off` downgrades a would-be denial to observe, while `UNKNOWN_MODE`
    does NOT — a malformed mode must fail closed rather than silently disable enforcement (F10).

    An absent stanza still answers `off` HERE, on purpose — an ungoverned repo must not start denying
    because it never opted in. `pathway_mode_state()` is what tells the two apart for reporting."""
    state, value = _pathway_block_value(repo, "mode")
    if state != PATHWAY_KEY_DECLARED:
        return "off"
    return value if value in PATHWAY_MODES else UNKNOWN_MODE


def pathway_attempt_ceiling(repo: str):
    """Read `pathway_enforcement.attempt_ceiling` from WORKFLOW-config.yaml without a YAML dependency.

    Returns one of:
      * the configured POSITIVE INTEGER, when the config declares a valid one;
      * `None` — the value is ABSENT: the config is unreadable/missing or declares no `attempt_ceiling`
        key at all. The caller silently supplies the built-in default (an unset value is not an error).
      * `MALFORMED_ATTEMPT_CEILING` — the config DECLARES an `attempt_ceiling` that is not a positive
        integer (a typo like `banana`, `-5`, or a blank value). Distinguished from ABSENT so the caller
        can surface the operator's mistake instead of silently swallowing it, mirroring `pathway_mode`'s
        ABSENT(`off`) vs MALFORMED(`UNKNOWN_MODE`) split (F23). Not a fail-open — the ceiling only bounds
        a retry loop, so a malformed value still errs to the safe default — but the silent swallow hid
        the config error."""
    state, value = _pathway_block_value(repo, "attempt_ceiling")
    if state != PATHWAY_KEY_DECLARED:
        return None
    try:
        parsed = int(value)
    except ValueError:
        return MALFORMED_ATTEMPT_CEILING              # declared but not an integer
    return parsed if parsed > 0 else MALFORMED_ATTEMPT_CEILING  # declared but non-positive


def current_branch(repo: str) -> str:
    return _run_git(repo, "branch", "--show-current")


def _has_git_metadata(repo: str) -> bool:
    current = repo_root(repo)
    while True:
        if os.path.lexists(os.path.join(current, ".git")):
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return False
        current = parent


def git_path(repo: str, relpath: str) -> str:
    try:
        out = _run_git(repo, "rev-parse", "--git-path", relpath)
    except RuntimeError:
        if _has_git_metadata(repo):
            raise
        return os.path.normpath(os.path.join(repo_root(repo), ".idc", relpath))
    return os.path.normpath(out if os.path.isabs(out) else os.path.join(repo, out))


def auth_path(repo: str) -> str:
    return git_path(repo, AUTH_RELPATH)


def admission_lock_path(repo: str) -> str:
    return git_path(repo, ADMISSION_LOCK_RELPATH)


def live_contract_path(repo: str) -> str:
    return git_path(repo, LIVE_CONTRACT_RELPATH)


def git_common_path(repo: str, relpath: str) -> str:
    """`relpath` under the repository's COMMON git directory — the one every worktree shares.

    `git_path` resolves PER WORKTREE: inside a linked worktree `--git-path X` lands under
    `.git/worktrees/<name>/X`. That is right for per-worktree session state (the authorization, the
    admission lock) and WRONG for repository-wide evidence, which must read the same from every
    checkout. Same resolution the build-validation witness store uses (#197/#199)."""
    try:
        out = _run_git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    except RuntimeError:
        try:
            out = _run_git(repo, "rev-parse", "--git-common-dir")   # git < 2.31 has no --path-format
        except RuntimeError:
            if _has_git_metadata(repo):
                raise
            return os.path.normpath(os.path.join(repo_root(repo), ".idc", relpath))
    common = out if os.path.isabs(out) else os.path.join(repo, out)
    return os.path.normpath(os.path.join(common, relpath))


def uninstall_witness_path(repo: str) -> str:
    """REPOSITORY-WIDE, so it resolves through the COMMON git dir, never `git_path` (#202 review).

    `/idc:uninstall` may run in a linked worktree, while the push that must honor its witness happens
    wherever the operator pushes from. Under `--git-path` the witness would be written to that
    worktree's private git dir: invisible to a push from the primary checkout or a sibling worktree,
    and DELETED outright with the worktree — stranding the very commit it attests to."""
    return git_common_path(repo, UNINSTALL_WITNESS_RELPATH)


def _read_live_contract(repo: str) -> tuple[str, dict[str, Any] | None]:
    """Read the live-contract pointer: ('absent'|'unreadable'|'corrupt'|'ok', doc)."""
    path = live_contract_path(repo)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unreadable", None
    except ValueError:
        return "corrupt", None
    if not isinstance(data, dict):
        return "corrupt", None
    return "ok", data


def record_live_contract(repo: str, doc: dict[str, Any], contract_path: str) -> dict[str, Any]:
    """Publish the just-frozen validation contract as this repository's live contract.

    Called ONLY by `idc_validation_contract.freeze_contract` (fixed code), immediately after the
    contract file and its out-of-tree witness are written. The pointer records WHERE the contract
    lives and its digest; the scope itself is always re-read from the verified contract file (the
    real data), never from this pointer."""
    pointer = {
        "schema": 1,
        "contract_path": os.path.realpath(os.path.abspath(contract_path)),
        "contract_digest": doc.get("contract_digest"),
        "issue": doc.get("issue"),
        "pr": doc.get("pr"),
        "graph_node": doc.get("graph_node"),
        "recorded_at": _iso(_utc_now()),
    }
    _atomic_write_json(live_contract_path(repo), pointer)
    return pointer


def clear_live_contract(repo: str, expected_issue=None) -> bool:
    """Retire the live-contract pointer when its claimed unit reaches a terminal Status.

    With `expected_issue`, a READABLE pointer for a DIFFERENT issue is left in place (never clear
    another unit's live contract); an unreadable/corrupt pointer is removed either way (repair)."""
    state, pointer = _read_live_contract(repo)
    if state == "absent":
        return True
    if state == "ok" and expected_issue is not None \
            and str((pointer or {}).get("issue")) != str(expected_issue):
        return False
    try:
        os.remove(live_contract_path(repo))
    except FileNotFoundError:
        pass
    return True


def contract_scope(repo: str) -> dict[str, Any] | None:
    """The live frozen validation contract's mint scope, or None when no contract is recorded.

    FAIL-CLOSED: an unreadable/corrupt pointer, a contract file that fails `load_contract`
    verification (self-digest + out-of-tree witness), or a pointer that no longer matches the frozen
    contract raises RuntimeError — the caller must refuse to mint a broad authorization over a state
    it cannot verify, never silently widen. The scope is derived from the VERIFIED contract document
    (its `touch` / `off_limits` sets), not from the pointer."""
    state, pointer = _read_live_contract(repo)
    if state == "absent":
        return None
    if state != "ok":
        raise RuntimeError(f"the live validation-contract pointer is {state}")
    contract_path = str((pointer or {}).get("contract_path") or "")
    if not contract_path:
        raise RuntimeError("the live validation-contract pointer names no contract file")
    # Lazy sibling import: idc_validation_contract lazily imports THIS module for the attempt
    # ceiling, so a top-level import here would be circular.
    import idc_validation_contract as VC  # noqa: PLC0415 — see above
    try:
        doc = VC.load_contract(contract_path)
    except Exception as exc:  # noqa: BLE001 — any verification failure fails the mint closed
        raise RuntimeError(
            f"the live frozen validation contract failed verification: {CS.scrub(str(exc))}"
        ) from exc
    if doc.get("contract_digest") != pointer.get("contract_digest"):
        raise RuntimeError(
            "the live validation-contract pointer no longer matches the frozen contract digest")
    touch = [t for t in (doc.get("touch") or []) if isinstance(t, str) and t.strip()]
    off_limits = [t for t in (doc.get("off_limits") or []) if isinstance(t, str) and t.strip()]
    if not touch:
        raise RuntimeError("the live frozen validation contract declares no touch surfaces")
    return {
        "issue": doc.get("issue"),
        "allowed_paths": touch,
        "denied_paths": off_limits,
        "ticket": str(doc.get("issue")),
        "graph_node": str(doc.get("graph_node") or "") or None,
        "validation_contract_digest": str(doc.get("contract_digest") or ""),
    }


@contextlib.contextmanager
def admission_lock(repo: str):
    """Serialize command-entry registration -> authorization/rollback across processes.

    This safety lock is fail-closed (unlike the ledger's best-effort observer lock): without it two
    admission processes can overwrite the same active record between start and authorization. Lock
    order is admission lock -> ledger write lock -> authorization atomic write; no code acquires the
    admission lock from inside either lower-level lock."""
    if fcntl is None:
        raise RuntimeError("Path Gate admission locking is unavailable on this platform")
    path = admission_lock_path(repo)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        fh = open(path, "a", encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot open Path Gate admission lock: {CS.scrub(str(exc))}") from exc
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        except OSError as exc:
            raise RuntimeError(f"cannot acquire Path Gate admission lock: {CS.scrub(str(exc))}") from exc
        yield
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        fh.close()


def _atomic_write_json(path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".idc-path-gate.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def ordered_uninstall_witness(repo: str) -> list[str]:
    """The uninstall commit OIDs a sanctioned door recorded, oldest first.

    TOLERANT ON READ AND FAIL-CLOSED ON DOUBT: a missing, unreadable, corrupt or wrong-shaped witness
    reads as EMPTY. Empty grants no exemption, so every failure mode of this file lands on "the push
    is gated normally" — never on "the push is waved through"."""
    try:
        with open(uninstall_witness_path(repo), encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(doc, dict) or doc.get("schema") != 1:
        return []
    entries = doc.get("uninstall_commits")
    if not isinstance(entries, list):
        return []
    ordered: list[str] = []
    for entry in entries:
        if not isinstance(entry, str):
            continue
        oid = entry.strip().lower()
        if _OID_RE.fullmatch(oid) and oid not in ordered:
            ordered.append(oid)
    return ordered


def read_uninstall_witness(repo: str) -> set[str]:
    """Set form of `ordered_uninstall_witness` — the membership test the push gate uses."""
    return set(ordered_uninstall_witness(repo))


def _commits_present(repo: str, oids: list[str]) -> set[str] | None:
    """The subset of `oids` that still resolve to a commit object here, or None if git cannot answer.

    One `cat-file --batch-check` for the whole set. None means "do not prune" — every uncertainty
    (git missing, non-zero exit, a reply that does not line up one-to-one with the request) keeps
    every entry, because dropping a witness the repository still needs re-strands its commit."""
    if not oids:
        return set()
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "--batch-check=%(objecttype)"],
        input="".join(f"{oid}^{{commit}}\n" for oid in oids),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    lines = (proc.stdout or "").splitlines()
    if len(lines) != len(oids):
        return None
    return {oid for oid, line in zip(oids, lines) if line.strip() == "commit"}


@contextlib.contextmanager
def uninstall_witness_lock(repo: str):
    """Serialize the uninstall-witness read → prune → write across concurrent recorders (#202 review).

    Same mechanism as the build-validation witness store's `_witness_store_lock`, for the same reason
    and on the same kind of file: ONE shared store in the git COMMON dir, written by processes that
    can run concurrently in different linked worktrees of the same repository. `os.replace` makes the
    final swap atomic, but each recorder does read-whole-store → mutate → replace, and the read→mutate
    is NOT inside that atom: two recorders that both read the pre-image lose-update, and the discarded
    entry re-strands the uninstall commit it attested to — the exact permanent-unpushability this door
    exists to prevent. The lock lives beside the store under the common git dir, so every worktree
    contends for the same one. On a platform without `fcntl` it degrades to a no-op (best-effort, as
    in the validation store); the plugin's supported hosts are POSIX."""
    if fcntl is None:
        yield
        return
    path = uninstall_witness_path(repo) + ".lock"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def record_uninstall_commit(repo: str, oid: str) -> list[str]:
    """Record one uninstall commit OID in the witness (idempotent, newest-last, UNBOUNDED).

    The CALLER is responsible for having proven the commit's shape first; this is the storage half
    only. `idc_git_path_gate.py witness-uninstall` is the sole production caller and it refuses
    anything that is not the ungoverning shape.

    NO FIXED RETENTION CAP (#202 review). A cap is unsound here however large it is set, because
    pre-push inspects EVERY commit of the outgoing range while the store remembers only the last N:
    a range carrying more than N genuine uninstall commits — a first push to a new mirror after many
    uninstall/re-init cycles — can never be made pushable, since re-witnessing an evicted entry just
    evicts another one the same range still needs. Growth is bounded instead by the only prune that
    is provably lossless: an OID whose commit is no longer in this object database can never be
    exempted anyway (`uninstall_commit_problem` refuses what it cannot resolve), so dropping it
    changes no decision.

    THE WHOLE READ → PRUNE → WRITE RUNS UNDER `uninstall_witness_lock` (#202 review). Concurrent
    recorders in different linked worktrees share one store, and without the lock the second writer's
    replace discards the first writer's entry — re-stranding a commit that was correctly witnessed."""
    normalized = str(oid).strip().lower()
    if not _OID_RE.fullmatch(normalized):
        raise ValueError("an uninstall witness entry must be a full commit object id")
    with uninstall_witness_lock(repo):
        entries = [e for e in ordered_uninstall_witness(repo) if e != normalized]
        present = _commits_present(repo, entries)
        if present is not None:
            entries = [e for e in entries if e in present]
        entries.append(normalized)
        _atomic_write_json(uninstall_witness_path(repo), {"schema": 1, "uninstall_commits": entries})
    return entries


def authorization_snapshot(repo: str) -> bytes | None:
    """Exact authorization bytes for command-entry rollback, or None when absent."""
    try:
        with open(auth_path(repo), "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def _atomic_write_bytes(path: str, payload: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".idc-path-gate.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def restore_authorization_snapshot(repo: str, snapshot: bytes | None, expected_nonce: str) -> bool:
    """Restore exact pre-admission auth iff current auth is this attempt (nonce CAS).

    Called only while `admission_lock` is held and before command expansion. There is deliberately no
    CLI operation for this internal transaction repair."""
    path = auth_path(repo)
    try:
        with open(path, "rb") as fh:
            current = fh.read()
    except FileNotFoundError:
        current = None
    if current == snapshot:
        return True
    try:
        decoded = json.loads(current.decode("utf-8")) if current is not None else None
    except (UnicodeDecodeError, ValueError):
        return False
    if not isinstance(decoded, dict) or decoded.get("nonce") != str(expected_nonce):
        return False
    if snapshot is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        _atomic_write_bytes(path, snapshot)
    try:
        with open(path, "rb") as fh:
            restored = fh.read()
    except FileNotFoundError:
        restored = None
    return restored == snapshot


def _request_repo_rel(path_value: str, repo: str) -> str | None:
    if not isinstance(path_value, str) or not path_value.strip():
        raise ValueError("path must be a non-empty string")
    raw = path_value.strip()
    repo_abs = repo_root(repo)
    abs_path = os.path.realpath(raw if os.path.isabs(raw) else os.path.join(repo_abs, raw))
    rel = os.path.relpath(abs_path, repo_abs)
    if rel == ".":
        return "."
    if rel.startswith("..") or os.path.isabs(rel):
        return None
    return rel.replace(os.sep, "/")


def _normalize_repo_rel(path_value: str, repo: str) -> str:
    rel = _request_repo_rel(path_value, repo)
    if rel is None:
        raise ValueError(f"{path_value!r} escapes the repository root")
    return rel


def _normalize_allowed_paths(repo: str, paths: list[str]) -> list[str]:
    out = []
    for item in paths:
        rel = _normalize_repo_rel(item, repo)
        if rel.endswith("/") and rel != "/":
            rel = rel.rstrip("/")
        if rel not in out:
            out.append(rel)
    return out or ["."]


def _normalize_denied_paths(repo: str, paths: list[str]) -> list[str]:
    """Like _normalize_allowed_paths but an EMPTY set stays empty — the allowed-side default of
    `["."]` (whole repo) would flip an empty deny set into deny-everything."""
    out = []
    for item in paths or []:
        rel = _normalize_repo_rel(item, repo)
        if rel.endswith("/") and rel != "/":
            rel = rel.rstrip("/")
        if rel not in out:
            out.append(rel)
    return out


def _path_allowed(relpath: str, allowed_paths: list[str]) -> bool:
    for rule in allowed_paths:
        base = rule.rstrip("/") or "."
        if base == ".":
            return True
        if relpath == base or relpath.startswith(base + "/"):
            return True
    return False


def _is_protected_machine_path(relpath: str) -> bool:
    candidate = relpath.casefold()
    return any(fnmatch.fnmatchcase(candidate, rule.casefold()) for rule in PROTECTED_MACHINE_RULES)


def _contains_protected_machine_path(relpath: str) -> bool:
    """Whether a broad directory target can reach a protected descendant."""
    candidate = relpath.casefold().strip("/") or "."
    if candidate == ".":
        return True
    for rule in PROTECTED_MACHINE_RULES:
        wildcard_at = min(
            (index for mark in "*?[" if (index := rule.find(mark)) >= 0),
            default=len(rule),
        )
        fixed_prefix = rule[:wildcard_at].rstrip("/").casefold()
        if fixed_prefix and fixed_prefix.startswith(candidate + "/"):
            return True
    return False


# The protected surfaces that are APPEND-ONLY MACHINE LOGS, and so must be PUBLISHABLE. The transition
# journal has to travel with the repository — the janitor reports a non-empty board with no journal as
# INDETERMINATE, so a gitignored journal (the remedy #184 used for the install receipt) would break
# every fresh clone — and every sanctioned board write appends to it. A commit that merely RECORDS one
# of these is ordinary forward progress, not a hand-repair, so the git backstops let it through.
#
# DELIBERATELY NARROW — do not widen this to the rest of PROTECTED_MACHINE_RULES. `TRACKER.md` in
# particular IS the filesystem board, and refusing a hand-edited tracker at publish time is a tested
# guard (`tests/smoke/governance/uninstall-push-door.sh` case 3 pushes a stray hand edit and requires
# the refusal; `path-gate-git-backstops.sh` requires a smuggled lower-commit edit to be caught even
# when the tip restores the tree). Those files are machine-local or re-mintable; this one is a log
# that has to reach the remote.
RECORDABLE_MACHINE_LOG_RULES = [
    "docs/workflow/transition-journal.ndjson",
    "docs/workflow/transition-journal.ndjson.*",
]


def is_recordable_machine_log(relpath: str) -> bool:
    """Is `relpath` an append-only machine log a commit may carry? See RECORDABLE_MACHINE_LOG_RULES.

    Only ever consulted for a RECORD (add/modify) by the git backstops. A REMOVAL of one of these is
    still a protected mutation, so the uninstall push door (#201) is untouched, and the write doors
    (Write/Edit/Bash) still refuse hand-editing it through `is_protected_machine_surface`."""
    candidate = relpath.casefold()
    return any(fnmatch.fnmatchcase(candidate, rule.casefold()) for rule in RECORDABLE_MACHINE_LOG_RULES)


def is_protected_machine_surface(relpath: str) -> bool:
    """Public form of the protected-surface test, for sanctioned adapters (the git backstops).

    Deliberately the SAME disjunction `_evaluate_request` denies on, so an adapter that needs to know
    which of its paths the gate would refuse cannot drift from the gate's own answer."""
    return _is_protected_machine_path(relpath) or _contains_protected_machine_path(relpath)


def _find_active_record_by_nonce(repo: str, command: str, nonce: str) -> dict[str, Any] | None:
    state = L.read_state(repo)
    for rec in state.get("commands", []):
        if rec.get("state") == "active" and rec.get("command") == command and rec.get("nonce") == nonce:
            return rec
    return None


MUTATION_ACTIONS = ("write", "edit", "git")


def _normalize_actions(actions: list[str]) -> list[str]:
    """Canonical action tokens: stripped, lowercased, empties dropped, order-preserving de-dupe.

    Enforcement (`_evaluate_request`) already compares the requested action against the stored
    `allowed_actions` on this normalized form. So an authorization MUST be normalized to the same form
    BEFORE the role-action-ceiling check and BEFORE storage — otherwise a cased or whitespace-padded
    token (`Write`, ` write `) slips the ceiling (`"Write" not in MUTATION_ACTIONS`) yet is later
    matched by a lowercase enforcement request, minting the very grant the ceiling exists to refuse
    (F17)."""
    normalized: list[str] = []
    for raw in actions or []:
        token = str(raw).strip().lower()
        if token and token not in normalized:
            normalized.append(token)
    return normalized


# Commands whose ENTRY mint carries no mutation actions: write authority for them is issued by the
# CLAIM transaction (spec §3.3 "No source-write authorization is issued before a Build claim is
# proven In Progress", §4.2 "A successful claim transaction issues the limited Path Gate
# authorization"). `build` is claim-gated; `autorun` deliberately is NOT — its entry mint stays
# broad because the drain performs sanctioned non-claim mutations between items, and every claim it
# makes still re-mints the claim-scoped grant below.
CLAIM_GATED_COMMANDS = {"build"}


def _default_profile(command: str) -> tuple[list[str], list[str]]:
    if command in READ_ONLY_COMMANDS or command in CLAIM_GATED_COMMANDS:
        return ["."], []
    return ["."], ["write", "edit", "git"]


def _role_action_ceiling(command: str) -> set[str]:
    """The mutation actions a command's ROLE may ever be granted. A read-only command
    (`doctor`/`pause`) has an empty ceiling — it can never mint a write/edit/git grant, no matter what
    actions a caller passes to `write_authorization` (F2). Deliberately NOT derived from
    `_default_profile`: a claim-gated command (build) has an EMPTY entry default yet a full mutation
    ceiling — the claim transaction, not the entry, is what grants it."""
    if command in READ_ONLY_COMMANDS:
        return set()
    return set(MUTATION_ACTIONS)


def resolve_entry_profile(repo: str, command: str) -> dict[str, Any]:
    """The write_authorization kwargs a COMMAND-ENTRY mint uses (V-AUTH stages 1+2, spec §3.3/§4.2).

    For `build`, when a frozen validation contract is live in this repository, the entry mint is
    CONTRACT-SCOPED: allowed_paths = the contract's `touch` set, denied_paths = its `off_limits` set
    (touch − off_limits at evaluation time, deny winning), bound to the contract's ticket/graph-node
    identity — so a mutation outside the frozen boundary is refused when it is attempted, not first
    at receipt time. With no live contract, build's entry mint is READ-ONLY-UNTIL-CLAIM (paths `.`
    but NO mutation actions — the claim transaction is what issues write authority, spec §3.3); any
    non-build command keeps its default profile. A pointer/contract that exists but cannot be
    VERIFIED raises (contract_scope), so admission fails closed rather than silently minting
    broad."""
    paths, actions = _default_profile(command)
    profile: dict[str, Any] = {"allowed_paths": paths, "allowed_actions": actions}
    if command != "build":
        return profile
    scope = contract_scope(repo)
    if scope is None:
        return profile
    return {
        "allowed_paths": list(scope["allowed_paths"]),
        "denied_paths": list(scope["denied_paths"]),
        "allowed_actions": ["write", "edit", "git"],
        "ticket": scope["ticket"],
        "graph_node": scope["graph_node"],
        "validation_contract_digest": scope["validation_contract_digest"],
    }


# ── claim-time authorization (V-AUTH stage 2 — the spec's seam, §3.3/§4.2) ───────────────────────
# Write authority for a claim-gated command is issued by the CLAIM transaction, after the board
# write is proven and journaled, and retired when the item reaches a terminal Status. The mint binds
# to the newest ACTIVE record of a command that legitimately drives claims, so the grant dies with
# that record exactly like every other authorization.
CLAIM_BACKING_COMMANDS = ("build", "autorun")


def _active_claim_backing_record(repo: str) -> dict[str, Any] | None:
    state = L.read_state(repo)
    candidates = [
        rec for rec in state.get("commands", [])
        if rec.get("state") == "active" and rec.get("command") in CLAIM_BACKING_COMMANDS
        and rec.get("nonce") and rec.get("session_id")
    ]
    return candidates[-1] if candidates else None


def mint_claim_authorization(repo: str, num) -> dict[str, Any] | None:
    """Mint the claim-scoped authorization for board item `num` (spec §4.2: "A successful claim
    transaction issues the limited Path Gate authorization").

    Returns None when the mint is NOT APPLICABLE — a non-Git repo, or no active build/autorun
    command record to bind (the legacy/recordless flows, where nothing could enforce the grant
    anyway: evaluation requires the bound record to be active). When a frozen validation contract is
    live FOR THIS ISSUE (a re-claim of an in-flight unit), the mint inherits its touch/off-limits
    scope; otherwise the claim grants the full mutation profile over the repository — the freeze
    that follows the claim narrows it (`narrow_authorization_to_contract`).

    TTL + RENEWAL (closes the "long drain dies at 4h" debt): every claim re-mints a FRESH
    DEFAULT_TTL_SECONDS window, so a drain's authorization renews at each item it claims instead of
    one entry mint covering the whole run; and because a claim of an already-In Progress item is an
    idempotent no-op on the board, RE-RUNNING THE CLAIM IS THE SANCTIONED RENEW DOOR for a single
    unit whose implementation outlives the window."""
    if not _is_git_worktree(repo):
        return None
    record = _active_claim_backing_record(repo)
    if record is None:
        return None
    scope = contract_scope(repo)  # raises on an unverifiable pointer/contract → the claim reports it
    kwargs: dict[str, Any] = {
        "ticket": str(num),
        "graph_node": f"ticket:{num}",
        "allowed_paths": ["."],
        "denied_paths": [],
        "allowed_actions": list(MUTATION_ACTIONS),
    }
    if scope is not None and str(scope.get("issue")) == str(num):
        kwargs.update({
            "allowed_paths": list(scope["allowed_paths"]),
            "denied_paths": list(scope["denied_paths"]),
            "graph_node": scope["graph_node"] or kwargs["graph_node"],
            "validation_contract_digest": scope["validation_contract_digest"],
        })
    with admission_lock(repo):
        return write_authorization(
            repo,
            session=str(record.get("session_id")),
            command=str(record.get("command")),
            expected_nonce=str(record.get("nonce")),
            ttl_seconds=DEFAULT_TTL_SECONDS,
            **kwargs,
        )


def narrow_authorization_to_contract(repo: str) -> dict[str, Any] | None:
    """Re-mint the live authorization down to the just-frozen contract's boundary (V-AUTH stage 2).

    Called by `freeze_contract` immediately after the live-contract pointer is published. Returns
    None when there is nothing to narrow (no live authorization, or its bound record is no longer
    active — the next mint inherits the scope from the pointer instead). FAIL-CLOSED on state it
    cannot verify, and REFUSES a cross-unit freeze: a live authorization bound to a DIFFERENT ticket
    than the contract's issue is a unit-identity confusion, not a narrowing."""
    scope = contract_scope(repo)
    if scope is None:
        raise RuntimeError("no live validation contract is recorded")
    if not _is_git_worktree(repo):
        return None
    auth_state, auth = _read_authorization(repo)
    if auth_state == "absent":
        return None
    if auth_state != "ok" or not isinstance(auth, dict):
        raise RuntimeError(f"the live authorization is {auth_state}")
    record = _find_active_record_by_nonce(
        repo, str(auth.get("command") or ""), str(auth.get("nonce") or ""))
    if record is None:
        return None
    ticket = auth.get("ticket")
    if ticket is not None and str(ticket) != str(scope.get("issue")):
        raise RuntimeError(
            f"the live authorization is bound to ticket {ticket!r} but the frozen contract is for "
            f"issue {scope.get('issue')!r} — refusing the cross-unit narrowing")
    with admission_lock(repo):
        return write_authorization(
            repo,
            session=str(record.get("session_id")),
            command=str(auth.get("command")),
            expected_nonce=str(auth.get("nonce")),
            allowed_paths=list(scope["allowed_paths"]),
            denied_paths=list(scope["denied_paths"]),
            allowed_actions=list(MUTATION_ACTIONS),
            ticket=str(scope["issue"]),
            graph_node=scope["graph_node"],
            ttl_seconds=DEFAULT_TTL_SECONDS,
            validation_contract_digest=scope["validation_contract_digest"],
        )


def retire_claim_authorization(repo: str, num) -> tuple[bool, str]:
    """Retire the claim-scoped authorization when item `num` reaches a terminal Status (spec §4.2:
    "The authorization expires after finish or block. It cannot be reused for another ticket.").

    Clears the live-contract pointer for this issue, then — when the live authorization is bound to
    this item's ticket and its command record is still active — re-mints that record's ENTRY profile
    (build: read-only-until-claim; autorun: its broad default, with a fresh TTL — which is how a
    drain's authorization also renews at each finish). Returns (ok, detail); the caller decides how
    loudly a failure surfaces (the terminal board write has already landed)."""
    clear_live_contract(repo, expected_issue=num)
    if not _is_git_worktree(repo):
        return True, "not a Git worktree"
    auth_state, auth = _read_authorization(repo)
    if auth_state == "absent":
        return True, "no live authorization"
    if auth_state != "ok" or not isinstance(auth, dict):
        return False, f"the live authorization is {auth_state}"
    if auth.get("ticket") != str(num):
        return True, "the live authorization is not bound to this item"
    command = str(auth.get("command") or "")
    record = _find_active_record_by_nonce(repo, command, str(auth.get("nonce") or ""))
    if record is None:
        # The bound record is gone, so evaluation already denies everything under this auth.
        return True, "the bound command record is no longer active"
    profile = resolve_entry_profile(repo, command)
    with admission_lock(repo):
        write_authorization(
            repo,
            session=str(record.get("session_id")),
            command=command,
            expected_nonce=str(record.get("nonce")),
            **profile,
        )
    return True, "retired to the command entry profile"


def _digest_payload(record: dict[str, Any], auth: dict[str, Any]) -> str:
    payload = {
        "args_sha256": record.get("args_sha256", ""),
        "allowed_actions": list(auth.get("allowed_actions") or []),
        "allowed_paths": list(auth.get("allowed_paths") or []),
        "branch": auth.get("branch", ""),
        "command": auth.get("command", ""),
        "denied_paths": list(auth.get("denied_paths") or []),
        "graph_node": auth.get("graph_node", ""),
        "validation_contract_digest": auth.get("validation_contract_digest") or "",
        "nonce": auth.get("nonce", ""),
        "plugin_version": record.get("plugin_version", ""),
        "source": record.get("source", ""),
        "ticket": auth.get("ticket", ""),
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _deny(reason: str, remediation: str | None = None) -> dict[str, Any]:
    out = {"allowed": False, "reason": reason}
    if remediation:
        out["remediation"] = remediation
    return out


def _allow(reason: str) -> dict[str, Any]:
    return {"allowed": True, "reason": reason}


def _no_auth_reason() -> str:
    return (
        "IDC Path Gate denied this mutation because the live authorization is absent for this repository mutation. "
        "Route the work through an existing IDC command (think, intake, plan, build, recirculate, init, update, or a sanctioned recovery door) so IDC can open the sanctioned write path."
    )


def build_authorization(
    repo: str,
    *,
    record: dict[str, Any],
    command: str,
    branch: str,
    allowed_paths: list[str],
    allowed_actions: list[str],
    ticket: str | None,
    graph_node: str | None,
    ttl_seconds: int,
    denied_paths: list[str] | None = None,
    validation_contract_digest: str | None = None,
) -> dict[str, Any]:
    now = _utc_now()
    auth = {
        "schema": 1,
        "command": command,
        "ticket": ticket,
        "graph_node": graph_node or f"command:{command}",
        "branch": branch,
        "allowed_paths": allowed_paths,
        # The frozen contract's off-limits surfaces, enforced at mutation time: a path inside
        # `denied_paths` denies even when an `allowed_paths` prefix also covers it (deny wins),
        # mirroring the receipt-time `_boundary_problems` semantics.
        "denied_paths": list(denied_paths or []),
        "allowed_actions": allowed_actions,
        "issued_at": _iso(now),
        "expires_at": _iso(now + dt.timedelta(seconds=max(1, ttl_seconds))),
        "nonce": record.get("nonce", ""),
        # The spec's §3.2 schema calls this slot the "<validation-and-goal-contract-digest>": when
        # the mint was scoped by a frozen validation contract, this is THAT contract's own digest,
        # binding the authorization to the exact frozen gate it was minted from (V-AUTH stage 3).
        # Null when no contract scoped the mint. Folded into `contract_digest` below AND re-checked
        # against the live contract pointer at evaluation, so neither the field nor the live
        # contract can drift without the authorization dying.
        "validation_contract_digest": validation_contract_digest or None,
    }
    auth["contract_digest"] = _digest_payload(record, auth)
    return auth


def write_authorization(
    repo: str,
    *,
    session: str,
    command: str,
    branch: str | None = None,
    allowed_paths: list[str] | None = None,
    allowed_actions: list[str] | None = None,
    ticket: str | None = None,
    graph_node: str | None = None,
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
    expected_nonce: str | None = None,
    denied_paths: list[str] | None = None,
    validation_contract_digest: str | None = None,
) -> dict[str, Any]:
    records = [rec for rec in C.active_records(repo, session) if rec.get("command") == command]
    if not records:
        raise RuntimeError(f"no active command record found for session={session!r}, command={command!r}")
    if expected_nonce is not None:
        record = next(
            (rec for rec in records if rec.get("nonce") == str(expected_nonce)),
            None,
        )
        if record is None:
            raise RuntimeError(
                "active command record no longer matches the expected admission nonce; "
                "the admission attempt is no longer current"
            )
    else:
        record = records[0]
    if not record.get("nonce"):
        raise RuntimeError("active command record carries no nonce")
    if branch is None:
        branch = current_branch(repo) if _is_git_worktree(repo) else ""
    if allowed_paths is None or allowed_actions is None:
        def_paths, def_actions = _default_profile(command)
        allowed_paths = def_paths if allowed_paths is None else allowed_paths
        allowed_actions = def_actions if allowed_actions is None else allowed_actions
    # Normalize the requested actions to enforcement's canonical form (strip/lowercase/dedupe) ONCE,
    # before both the ceiling check and storage. This is load-bearing: the ceiling compares against
    # the lowercase MUTATION_ACTIONS and enforcement matches on the same normalized form, so a cased
    # or padded token must be canonicalized here or it would slip the ceiling yet still satisfy a
    # real lowercase request (F17).
    allowed_actions = _normalize_actions(allowed_actions)
    # Enforce the command's role action ceiling: a read-only command can never be granted a mutation
    # action, even when one is explicitly requested. This closes the escalation where any active
    # record — including a read-only doctor/pause record — could mint a broad write/edit/git grant.
    ceiling = _role_action_ceiling(command)
    over_ceiling = [a for a in allowed_actions if a in MUTATION_ACTIONS and a not in ceiling]
    if over_ceiling:
        raise RuntimeError(
            f"command {command!r} is read-only and may not be granted mutation action(s) "
            f"{sorted(set(over_ceiling))}: a read-only command record cannot mint a write/edit/git "
            f"authorization"
        )
    auth = build_authorization(
        repo,
        record=record,
        command=command,
        branch=branch,
        allowed_paths=_normalize_allowed_paths(repo, list(allowed_paths)),
        allowed_actions=allowed_actions,
        ticket=ticket,
        graph_node=graph_node,
        ttl_seconds=ttl_seconds,
        denied_paths=_normalize_denied_paths(repo, list(denied_paths or [])),
        validation_contract_digest=validation_contract_digest,
    )
    _atomic_write_json(auth_path(repo), auth)
    return auth


def request_identity(repo: str) -> dict[str, Any]:
    """The ticket/graph-node identity a sanctioned adapter ECHOES into its request (V-AUTH stage 3).

    Reads the LIVE authorization: its `graph_node` always echoes; its `ticket` echoes only when
    non-null (the spec declares ticket nullable). An absent/unreadable/corrupt authorization echoes
    nothing — evaluation denies those states on its own, before identity is consulted. This is
    deliberately the ONLY sanctioned source of request identity: the gate then requires the request
    identity to be present and to match the live authorization, so a request built without
    consulting it is denied."""
    state, auth = _read_authorization(repo)
    if state != "ok" or not isinstance(auth, dict):
        return {}
    identity: dict[str, Any] = {}
    graph_node = auth.get("graph_node")
    if isinstance(graph_node, str) and graph_node:
        identity["graph_node"] = graph_node
    ticket = auth.get("ticket")
    if ticket is not None:
        identity["ticket"] = ticket
    return identity


def _read_authorization(repo: str) -> tuple[str, dict[str, Any] | None]:
    path = auth_path(repo)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unreadable", None
    except ValueError:
        return "corrupt", None
    if not isinstance(data, dict):
        return "corrupt", None
    return "ok", data


def _evaluate_request(repo: str, plugin_root: str, request: dict[str, Any]) -> dict[str, Any]:
    del plugin_root  # reserved for future transport-specific helpers

    raw_reason = request.get("raw_reason")
    if isinstance(raw_reason, str) and raw_reason.strip():
        return _deny(raw_reason.strip())

    action = str(request.get("action") or "").strip().lower()
    raw_paths = request.get("paths") or []
    if isinstance(raw_paths, str):
        raw_paths = [raw_paths]
    if not isinstance(raw_paths, list):
        raw_paths = []
    try:
        paths = [
            rel
            for p in raw_paths
            if isinstance(p, str) and p.strip()
            for rel in [_request_repo_rel(p, repo)]
            if rel is not None
        ]
    except ValueError as exc:
        return _deny(f"IDC Path Gate denied this mutation because the requested path is invalid: {exc}")

    if not paths:
        return _allow("IDC Path Gate: no in-repository path-gated mutation was identified")

    for rel in paths:
        if _is_protected_machine_path(rel) or _contains_protected_machine_path(rel):
            return _deny(
                f"IDC Path Gate denied this mutation because `{rel}` is or contains a protected machine-owned surface. Use the sanctioned IDC helper instead of mutating it directly."
            )

    if not _is_git_worktree(repo):
        return _allow("IDC Path Gate: ordinary mutation is inside a governed non-Git repository")

    auth_state, auth = _read_authorization(repo)
    if auth_state == "absent":
        return _deny(_no_auth_reason())
    if auth_state == "unreadable":
        return _deny("IDC Path Gate denied this mutation because the live authorization is unreadable.")
    if auth_state == "corrupt":
        return _deny("IDC Path Gate denied this mutation because the live authorization is corrupt.")
    assert auth is not None

    if auth.get("schema") != 1:
        return _deny("IDC Path Gate denied this mutation because the authorization object is missing or has the wrong schema.")
    required = ("command", "branch", "allowed_paths", "denied_paths", "allowed_actions", "issued_at", "expires_at", "nonce", "contract_digest", "validation_contract_digest")
    for field in required:
        if field not in auth:
            return _deny(f"IDC Path Gate denied this mutation because the authorization object is missing `{field}`.")

    if action not in {str(x).strip().lower() for x in auth.get("allowed_actions") or []}:
        return _deny(f"IDC Path Gate denied this mutation because action `{action}` is not in the live authorization.")

    current = current_branch(repo)
    if auth.get("branch") != current:
        return _deny(
            f"IDC Path Gate denied this mutation because the live branch is `{current}` but the authorization is bound to `{auth.get('branch')}`."
        )

    expires_at = _parse_iso(str(auth.get("expires_at") or ""))
    if expires_at is None or expires_at <= _utc_now():
        return _deny("IDC Path Gate denied this mutation because the live authorization is expired or unreadable.")

    # Ticket / graph-node identity (spec §3.2) — REQUIRED AND MUST MATCH (V-AUTH stage 3, closing
    # review Blocker #3's denial clause). Every sanctioned adapter (the Claude interlock, the Pi
    # harness, the git backstops) ECHOES the identity it reads from the live authorization
    # (`request_identity`) into its request, so:
    #   * `graph_node` is required on every request — the live authorization always carries one — and
    #     must match exactly;
    #   * `ticket` is required exactly when the live authorization is ticket-bound (the spec declares
    #     `ticket` nullable — a null-ticket authorization requires the request to carry none), and
    #     must match exactly when present.
    # A request that arrives WITHOUT identity was not built by an adapter that consulted the live
    # authorization, and is denied. (The historical F3 objection — "denying missing identity breaks
    # every legitimate mutation because no adapter carries identity" — is resolved by the echo: all
    # three adapters now carry it.)
    graph_node = request.get("graph_node")
    if graph_node is None:
        return _deny(
            "IDC Path Gate denied this mutation because the request carries no graph-node identity. "
            "Sanctioned adapters echo `ticket`/`graph_node` from the live authorization into every request."
        )
    if graph_node != auth.get("graph_node"):
        return _deny("IDC Path Gate denied this mutation because the request graph node does not match the live authorization.")
    ticket = request.get("ticket")
    auth_ticket = auth.get("ticket")
    if auth_ticket is not None and ticket is None:
        return _deny(
            "IDC Path Gate denied this mutation because the request carries no ticket identity while the live authorization is ticket-bound. "
            "Sanctioned adapters echo `ticket`/`graph_node` from the live authorization into every request."
        )
    if ticket is not None and ticket != auth_ticket:
        return _deny("IDC Path Gate denied this mutation because the request ticket does not match the live authorization.")

    record = _find_active_record_by_nonce(repo, str(auth.get("command") or ""), str(auth.get("nonce") or ""))
    if not record:
        return _deny("IDC Path Gate denied this mutation because the bound command record is no longer active.")

    expected_digest = _digest_payload(record, auth)
    if auth.get("contract_digest") != expected_digest:
        return _deny("IDC Path Gate denied this mutation because the authorization contract digest is corrupt or stale.")

    # Frozen-contract binding (V-AUTH stage 3, spec §3.2 "<validation-and-goal-contract-digest>"):
    # an authorization minted under a frozen validation contract dies the moment that contract stops
    # being the LIVE one — a re-frozen gate, a cleared/tampered pointer. Re-mint through the
    # sanctioned doors (the claim, or the freeze) to continue.
    auth_vcd = auth.get("validation_contract_digest")
    if auth_vcd:
        pointer_state, pointer = _read_live_contract(repo)
        if pointer_state != "ok" or (pointer or {}).get("contract_digest") != auth_vcd:
            return _deny(
                "IDC Path Gate denied this mutation because the authorization is bound to a frozen validation contract that is no longer the live contract. "
                "Re-mint through the sanctioned claim/freeze doors."
            )

    # Deny wins over allow: a path inside the authorization's off-limits set is refused even when an
    # allowed prefix also covers it — the mutation-time twin of the receipt writer's
    # `_boundary_problems` off-limits refusal (spec §3.4 "declared touch and off-limits paths").
    denied_paths = _normalize_denied_paths(repo, list(auth.get("denied_paths") or []))
    for rel in paths:
        if denied_paths and _path_allowed(rel, denied_paths):
            return _deny(
                f"IDC Path Gate denied this mutation because `{rel}` is inside the live authorization's off-limits set ({', '.join(denied_paths)})."
            )

    allowed_paths = _normalize_allowed_paths(repo, list(auth.get("allowed_paths") or []))
    for rel in paths:
        if not _path_allowed(rel, allowed_paths):
            return _deny(
                f"IDC Path Gate denied this mutation because `{rel}` is outside the live authorization boundary ({', '.join(allowed_paths)})."
            )

    return _allow("IDC Path Gate: mutation is inside the live authorization boundary")


def _observe_cause(repo: str) -> str:
    """WHY this repository is only observing — appended to every downgraded denial.

    A bare "would deny" reads as though enforcement is on and merely lenient about this one mutation.
    It is not: the whole posture is non-enforcing, and the operator has no way to tell WHICH of the
    three reasons applies. Saying it at the point of use makes the downgrade self-diagnosing, which is
    what was missing when a github-backed repo ran fully unenforced because its config predated the
    `pathway_enforcement` stanza."""
    if os.environ.get("IDC_HOOKS_OBSERVE_ONLY", "") == "1":
        return "observe: IDC_HOOKS_OBSERVE_ONLY=1 is set in this environment"
    state = pathway_mode_state(repo)
    if state == PATHWAY_KEY_ABSENT:
        return ("observe: pathway_enforcement mode is 'off' — the stanza is ABSENT from "
                "WORKFLOW-config.yaml, so nothing is enforced. Run `/idc:doctor` for the stanza to paste")
    if state == PATHWAY_CONFIG_UNREADABLE:
        return ("observe: pathway_enforcement mode is 'off' — WORKFLOW-config.yaml is missing or "
                "unreadable, so no posture could be read. Run `/idc:doctor`")
    return "observe: pathway_enforcement mode is 'off' in WORKFLOW-config.yaml"


def evaluate_request(repo: str, plugin_root: str, request: dict[str, Any]) -> dict[str, Any]:
    """Evaluate once, then apply the repository's transport-independent enforcement posture."""
    decision = _evaluate_request(repo, plugin_root, request)
    if decision.get("allowed"):
        return decision
    if os.environ.get("IDC_HOOKS_OBSERVE_ONLY", "") == "1" or pathway_mode(repo) == "off":
        reason = str(decision.get("reason") or "IDC Path Gate would deny this mutation")
        return {
            "allowed": True,
            "observe": f"{reason} ({_observe_cause(repo)})",
        }
    return decision


def _read_request_from_stdin() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise RuntimeError("request JSON must be an object")
    return data


def cmd_auth_path(args: argparse.Namespace) -> int:
    print(auth_path(repo_root(args.repo)))
    return 0


# DELIBERATELY NO `authorize` CLI VERB (V-DOOR). Minting an authorization is an ADMISSION-side
# privilege, not an agent-side one, so THIS module exposes no minting verb: `write_authorization` is
# reachable only through the Python API. The verb that used to live here honored caller-supplied
# `--command`/`--allow-action`/`--allow-path`, so ANY Bash in a session whose only precondition was
# "an active command record exists" could mint itself a broad write/edit/git grant over the whole
# repo, at any scope it named. Do not re-add it: a new legitimate minting need belongs on the Python
# API behind the admission lock, with the role-action ceiling (`_role_action_ceiling`) intact.
#
# WHAT IS AND IS NOT TRUE, PRECISELY (this comment previously claimed "the only two callers are
# admission code", which reads as "no agent-reachable mint remains" and is FALSE):
#   * Every production caller is fixed admission/transition code with NO caller-chosen scope:
#     `idc_command_entry_gate._ensure_path_gate_auth` (the UserPromptExpansion hook, profile from
#     `resolve_entry_profile`), `idc_command_contract._mint_or_rollback` (the self-minting init),
#     and — since V-AUTH stage 2 — this module's own `mint_claim_authorization` /
#     `narrow_authorization_to_contract` / `retire_claim_authorization`, whose scopes come from the
#     claim's board item and the machine-verified frozen validation contract, never from the caller.
#   * BUT two FIXED-profile self-serve mint paths remain, each self-servable from raw Bash in a
#     governed session — no caller-chosen scope, but no admission-side gate either:
#       (a) `idc_command_contract.py start --command init` opens an init record and receives init's
#           FIXED default profile (write/edit/git over `.`); precondition = a governed repository.
#       (b) `idc_command_contract.py start --command build` opens a build record (which mints NOTHING
#           on its own), then `idc_transition.py claim --num N` mints the claim-scoped grant —
#           write/edit/git over the whole repo (`.`), bound to ticket N — via mint_claim_authorization
#           below. Precondition = a claimable board item N; the scope is still the ticket's own FIXED
#           whole-repo grant (narrowed to touch/off_limits once the contract freezes), never the
#           caller's to name.
#     Neither is a caller-chosen-scope door; neither is a regression (init predates V-DOOR; the build
#     claim IS the sanctioned write seam). They are not closed here because the only admission-side
#     signal that could gate them comes from the Claude-only entry gate, which Codex and Pi never run:
#     these are the mint paths those runtimes have, so requiring an entry-gate token would deny every
#     commit they make in a `controlled` repository through the git backstops. Tracked in
#     `docs/dev/known-debts.md` ("Fixed-profile Path Gate self-mints remain self-servable").
# `governance/path-gate-boundaries.sh` asserts BOTH CLIs, each enumerated off its own parser.


def cmd_evaluate(args: argparse.Namespace) -> int:
    req = _read_request_from_stdin()
    decision = evaluate_request(repo_root(args.repo), args.plugin_root or "", req)
    print(json.dumps(decision, indent=2, sort_keys=True))
    return 0 if decision.get("allowed") else 2


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="op", required=True)

    p = sub.add_parser("auth-path")
    p.add_argument("--repo", required=True)
    p.set_defaults(func=cmd_auth_path)

    p = sub.add_parser("evaluate")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", default="")
    p.set_defaults(func=cmd_evaluate)

    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps(_deny(f"IDC Path Gate infrastructure error: {exc}"), indent=2, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
