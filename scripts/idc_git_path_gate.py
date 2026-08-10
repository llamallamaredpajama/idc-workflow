#!/usr/bin/env python3
"""Git backstops for the shared IDC Path Gate."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from typing import Iterable

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import idc_command_contract as C  # noqa: E402
import idc_credential_shapes as CS  # noqa: E402
import idc_path_gate as PG  # noqa: E402

MANAGED_MARKER = "IDC_PATH_GATE_MANAGED=1"
ORIGINAL_PREFIX = "IDC_PATH_GATE_ORIGINAL="


def _repo_root(repo: str) -> str:
    return os.path.abspath(repo)


def _git_path(repo: str, relpath: str) -> str:
    return PG.git_path(repo, relpath)


def _hook_path(repo: str, kind: str) -> str:
    return os.path.join(_hooks_dir(repo), kind)


def _hooks_dir(repo: str) -> str:
    hooks_dir = _git_path(repo, "hooks")
    common_dir = _run_git(repo, "rev-parse", "--git-common-dir")
    if not os.path.isabs(common_dir):
        common_dir = os.path.join(repo, common_dir)
    resolved_hooks = os.path.realpath(hooks_dir)
    resolved_common = os.path.realpath(common_dir)
    try:
        owned = os.path.commonpath((resolved_common, resolved_hooks)) == resolved_common
    except ValueError:
        owned = False
    if not owned:
        raise RuntimeError(
            f"refusing hooks directory outside repository common Git directory: {hooks_dir}"
        )
    return hooks_dir


def _backup_path(hook_path: str) -> str:
    return hook_path + ".idc-path-gate-original"


def _managed_content(kind: str, plugin_root: str, original_hook: str | None) -> str:
    wrapper = os.path.join(plugin_root, "scripts", "hooks", f"idc_git_{kind.replace('-', '_')}.sh")
    original = original_hook or ""
    header = (
        "#!/bin/sh\n"
        f"# {MANAGED_MARKER}\n"
        f"# IDC_PATH_GATE_KIND={kind}\n"
        f"# {ORIGINAL_PREFIX}{original}\n"
        "set -eu\n"
        f"PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
        f"IDC_ORIGINAL_HOOK={shlex.quote(original)}\n"
    )
    if kind == "pre-push":
        return (
            f"{header}"
            "IDC_PUSH_STDIN=$(mktemp \"${TMPDIR:-/tmp}/idc-path-gate-pre-push.XXXXXX\")\n"
            "idc_cleanup() { rm -f \"$IDC_PUSH_STDIN\"; }\n"
            "idc_reraise() {\n"
            "  IDC_SIGNAL=$1\n"
            "  trap - 0 \"$IDC_SIGNAL\"\n"
            "  idc_cleanup\n"
            "  kill -s \"$IDC_SIGNAL\" \"$$\"\n"
            "}\n"
            "trap 'idc_reraise HUP' HUP\n"
            "trap 'idc_reraise INT' INT\n"
            "trap 'idc_reraise TERM' TERM\n"
            "trap idc_cleanup 0\n"
            "cat > \"$IDC_PUSH_STDIN\"\n"
            f"sh {shlex.quote(wrapper)} \"$PLUGIN_ROOT\" \"$@\" < \"$IDC_PUSH_STDIN\"\n"
            "if [ -n \"$IDC_ORIGINAL_HOOK\" ] && [ -x \"$IDC_ORIGINAL_HOOK\" ]; then\n"
            "  \"$IDC_ORIGINAL_HOOK\" \"$@\" < \"$IDC_PUSH_STDIN\"\n"
            "fi\n"
            "exit 0\n"
        )
    return (
        f"{header}"
        f"sh {shlex.quote(wrapper)} \"$PLUGIN_ROOT\" \"$@\"\n"
        "if [ -n \"$IDC_ORIGINAL_HOOK\" ] && [ -x \"$IDC_ORIGINAL_HOOK\" ]; then\n"
        "  exec \"$IDC_ORIGINAL_HOOK\" \"$@\"\n"
        "fi\n"
        "exit 0\n"
    )


def _write_text(path: str, content: str) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(
        dir=parent,
        prefix=f".{os.path.basename(path)}.idc-path-gate-tmp-",
        text=True,
    )
    try:
        fh = os.fdopen(fd, "w", encoding="utf-8")
        fd = -1
        with fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(temp_path, 0o755)
        os.replace(temp_path, path)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def _read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _parse_original(content: str) -> str:
    for line in content.splitlines():
        if line.startswith(f"# {ORIGINAL_PREFIX}"):
            return line[len(f"# {ORIGINAL_PREFIX}") :]
    return ""


def install_hooks(repo: str, plugin_root: str) -> None:
    """Install atomically per hook; retry completes a recoverable partial pair.

    If the second hook fails, the first may already be managed. That state is intentional: the
    original error propagates unchanged, and a later call safely retries the missing second hook.
    """
    repo = _repo_root(repo)
    plugin_root = os.path.abspath(plugin_root)
    for kind in ("pre-commit", "pre-push"):
        hook = _hook_path(repo, kind)
        backup = _backup_path(hook)
        original = ""
        moved_original = False
        original_mode: int | None = None
        try:
            if os.path.exists(hook):
                try:
                    existing = _read_text(hook)
                except OSError:
                    existing = ""
                if MANAGED_MARKER in existing:
                    original = _parse_original(existing)
                else:
                    if os.path.exists(backup):
                        raise RuntimeError(
                            f"refusing to overwrite unmanaged {kind} hook while backup already exists: {hook}"
                        )
                    original_mode = stat.S_IMODE(os.stat(hook).st_mode)
                    os.replace(hook, backup)
                    moved_original = True
                    os.chmod(backup, os.stat(backup).st_mode | stat.S_IXUSR)
                    original = backup
            elif os.path.exists(backup):
                os.chmod(backup, os.stat(backup).st_mode | stat.S_IXUSR)
                original = backup
            content = _managed_content(kind, plugin_root, original)
            _write_text(hook, content)
        except Exception as exc:
            if moved_original and not os.path.exists(hook) and os.path.exists(backup):
                try:
                    os.replace(backup, hook)
                    if original_mode is not None:
                        os.chmod(hook, original_mode)
                except OSError as rollback_exc:
                    raise RuntimeError(
                        f"failed to install {kind} hook and restore its original: {rollback_exc}"
                    ) from exc
            raise


def verify_hooks(repo: str, plugin_root: str) -> tuple[bool, str]:
    repo = _repo_root(repo)
    plugin_root = os.path.abspath(plugin_root)
    for kind in ("pre-commit", "pre-push"):
        hook = _hook_path(repo, kind)
        if not os.path.isfile(hook):
            return False, f"missing {kind} hook at {hook}"
        if not os.access(hook, os.X_OK):
            return False, f"missing executable bit on {kind} hook at {hook}"
        try:
            current = _read_text(hook)
        except OSError as exc:
            return False, f"cannot read {kind} hook: {exc}"
        if MANAGED_MARKER not in current:
            return False, f"{kind} hook is not IDC-managed"
        original = _parse_original(current)
        expected = _managed_content(kind, plugin_root, original)
        if current != expected:
            return False, f"{kind} hook diverged from the IDC-managed content"
        if original and not os.path.exists(original):
            return False, f"{kind} hook references a missing chained original hook: {original}"
        if original and not os.access(original, os.X_OK):
            return False, f"{kind} chained original hook is not executable: {original}"
    return True, "ok"


def _run_git(repo: str, *args: str) -> str:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(CS.scrub(proc.stderr or proc.stdout or "git failed").strip())
    return (proc.stdout or "").strip()


# The diff statuses that mean a path is being RECORDED rather than REMOVED. Renames (`R`) are
# deliberately absent: a rename endpoint moves machine-owned state out of its contracted path, which is
# a removal in every sense the uninstall door cares about.
_RECORDED_STATUSES = frozenset("ACMT")


def _parse_name_status_z(out: str) -> list[tuple[str, str]]:
    """(status, path) records out of a `--name-status -z` payload; a rename/copy yields BOTH endpoints."""
    fields = [field for field in out.split("\0") if field != ""]
    records: list[tuple[str, str]] = []
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        # Rename/copy records carry two paths; every other status carries one.
        arity = 2 if status[:1] in {"R", "C"} else 1
        for _ in range(arity):
            if index >= len(fields):
                break
            records.append((status[:1], fields[index]))
            index += 1
    return records


def _drop_recorded_machine_state(records: Iterable[tuple[str, str]]) -> list[str]:
    """The gated path set for `records`, minus append-only machine logs the commit merely RECORDS.

    WHY THIS EXEMPTION EXISTS. Committing the transition journal is how the pipeline PUBLISHES it, not
    a hand-repair of it: it is clone-portable repo state (the janitor reports a non-empty board with no
    journal as INDETERMINATE, so it has to travel) and every sanctioned board write appends to it. The
    shared gate refuses a protected path BEFORE it consults the authorization, so under `controlled`
    that publish step was unshippable with nothing an authorization could ever do about it —
    `git add -A && git commit` died on the pipeline's own output. This is the trap #184 fixed for the
    install receipt by gitignoring it; that remedy is not available here, because a gitignored journal
    never reaches a clone.

    WHAT IS STILL DENIED, PRECISELY:
      * Only the narrow `PG.is_recordable_machine_log` family is dropped, NOT every protected surface.
        `TRACKER.md` and its peers stay refused, because refusing a hand-edited tracker at publish time
        is a deliberate, tested guard.
      * Only ADD/COPY/MODIFY/TYPECHANGE is dropped. A DELETE — or a rename endpoint — still reaches the
        gate, so the uninstall push door (issue #201) is untouched: removing machine-owned state remains
        admissible only for a witnessed, shape-verified uninstall commit, and "delete the anchor" still
        cannot become a universal key.
      * Hand-mutation is still refused where it HAPPENS rather than where it is recorded: the Write/Edit
        and Bash-writer doors evaluate these same paths through `PG.is_protected_machine_surface` and
        deny them unconditionally. This widens only what git plumbing may carry, which is the one thing
        no authorization could express.
    """
    paths: list[str] = []
    seen: set[str] = set()
    for status, rel in records:
        rel = rel.strip()
        if not rel or rel in seen:
            continue
        if status in _RECORDED_STATUSES and PG.is_recordable_machine_log(rel):
            continue
        seen.add(rel)
        paths.append(rel)
    return paths


def _collect_pre_commit_paths(repo: str) -> list[str]:
    out = _run_git(repo, "diff", "--cached", "--name-status", "-z", "--diff-filter=ACDMRTUXB")
    return _drop_recorded_machine_state(_parse_name_status_z(out))


def _remote_ref_shas(repo: str, remote: str) -> list[str]:
    if not remote:
        raise RuntimeError("actual push remote is required to inspect a new ref")
    out = _run_git(repo, "ls-remote", "--refs", remote)
    shas: list[str] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2 or not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", parts[0]):
            raise RuntimeError("git ls-remote returned an invalid server ref record")
        shas.append(parts[0])
    return shas


def _collect_pre_push_commits(
    repo: str,
    lines: Iterable[str],
    *,
    remote: str | None = None,
) -> list[tuple[str, list[str]]]:
    """Every outgoing commit paired with the paths IT touches, in push order.

    Attribution is per commit, not a flattened union, because a path's admissibility can depend on
    WHICH commit carries it: the sanctioned uninstall removal commit may delete a protected machine
    surface, while the identical path in any other commit may not (issue #201)."""
    commits: list[tuple[str, list[str]]] = []
    seen_commits: set[str] = set()
    server_shas: list[str] | None = None
    for line in lines:
        parts = line.strip().split()
        if len(parts) != 4:
            continue
        _, local_sha, _, remote_sha = parts
        if not local_sha or re.fullmatch(r"0+", local_sha):
            continue
        if remote_sha and not re.fullmatch(r"0+", remote_sha):
            exclusions = [remote_sha]
        else:
            if server_shas is None:
                server_shas = _remote_ref_shas(repo, remote or "")
            exclusions = server_shas
        try:
            reachable = _run_git(repo, "rev-list", local_sha, "--not", *exclusions).splitlines()
        except RuntimeError:
            reachable = [local_sha]
        for commit in reachable:
            commit = commit.strip()
            if not commit or commit in seen_commits:
                continue
            seen_commits.add(commit)
            out = _run_git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit)
            commits.append((commit, [rel.strip() for rel in out.splitlines() if rel.strip()]))
    return commits


def _collect_pre_push_paths(
    repo: str,
    lines: Iterable[str],
    *,
    remote: str | None = None,
) -> list[str]:
    """Flattened, de-duplicated outgoing paths — the full unexempted set."""
    paths: list[str] = []
    seen: set[str] = set()
    for _, rels in _collect_pre_push_commits(repo, lines, remote=remote):
        for rel in rels:
            if rel not in seen:
                seen.add(rel)
                paths.append(rel)
    return paths


# ── the uninstall push door (issue #201) ─────────────────────────────────────────────────────────
# `/idc:uninstall` must land its removal as ONE revertable commit, and that commit necessarily
# DELETES protected machine surfaces (`TRACKER.md`, the install receipt) alongside the governance
# anchor. The commit itself is admissible when it is made — both backstops are already dormant by
# then, because the anchor has left the worktree. But the pre-push backstop re-examines the whole
# OUTGOING RANGE under TODAY's posture, so the moment the repo is governed again (a fresh
# `/idc:init`, a `git revert`) that historical deletion is re-litigated and the push is refused
# forever, poisoning every later commit in the range.
#
# The door that resolves it binds to evidence, never to a commit message. Two INDEPENDENT checks must
# both hold before a commit's protected deletions are exempted:
#   1. a sanctioned door recorded the commit's own OID in the machine-owned witness, and
#   2. the gate re-derives the commit's shape from git AT PUSH TIME and confirms it.
# Check 2 is what makes the witness un-forgeable in practice: hand-editing the witness file buys
# nothing, because the shape is re-proven from the object database on every push.


def _commit_name_status(repo: str, commit: str) -> list[tuple[str, str]]:
    """(status, path) for every path the commit touches; a rename/copy yields BOTH endpoints."""
    return _parse_name_status_z(_run_git(
        repo, "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", commit
    ))


def _tree_has(repo: str, commit: str, relpath: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", f"{commit}:{relpath}"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def _tree_blob(repo: str, commit: str, relpath: str) -> bytes | None:
    """The exact bytes `relpath` had in `commit`'s tree, or None when those bytes are unavailable.

    None is AMBIGUOUS on purpose-of-caller: no entry, an entry that is not a blob, and a blob whose
    object is missing all answer None. Any caller for whom "absent" means something different from
    "present but unusable" must ask `_tree_entry_type` first (#202 review)."""
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "blob", f"{commit}:{relpath}"], capture_output=True
    )
    return proc.stdout if proc.returncode == 0 else None


def _tree_entry_type(repo: str, commit: str, relpath: str) -> str:
    """What `commit`'s tree records AT `relpath`: `blob`, `tree`, `commit` (a gitlink), `absent` when
    the tree carries no entry there, or `unknown` when git could not answer.

    Read straight off the TREE rather than by resolving the object, so a gitlink whose commit is not
    in this object database still answers `commit` instead of collapsing into "absent"."""
    proc = subprocess.run(
        ["git", "-C", repo, "ls-tree", "--full-tree", "-z", commit, "--", relpath],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return "unknown"
    record = (proc.stdout or "").split("\0")[0]
    if not record.strip():
        return "absent"
    header = record.split("\t", 1)[0].split()
    return header[1] if len(header) >= 2 else "unknown"


def _receipt_entries_in_tree(repo: str, commit: str):
    """`(entries, problem)` for the install receipt as of `commit`'s tree.

    `entries is None, problem is None` means this tree carries no receipt at all — a pre-receipt
    install, whose removal manifest is the fixed legacy list. A receipt that is THERE but unusable —
    it does not parse, or the tree records something other than a regular file at that path — is a
    hard problem and never falls back, mirroring `_uninstall_owned_files`: a damaged manifest must
    not be able to shrink the set of files an uninstall is required to have removed.

    ONLY A GENUINELY ABSENT RECEIPT MAY FALL BACK (#202 review). Blob bytes alone cannot tell the two
    apart — a directory, a gitlink, and an unreadable blob all read as "no bytes" — so the tree entry
    is inspected FIRST, and every present-but-not-a-blob shape is refused by name."""
    import idc_receipt_check as RC  # noqa: PLC0415 — lazy; the one canonical receipt parser

    kind = _tree_entry_type(repo, commit, RC.RECEIPT_RELPATH)
    if kind == "absent":
        return None, None
    if kind == "unknown":
        return None, (
            f"git could not report what commit {commit} carries at the install receipt path "
            f"`{RC.RECEIPT_RELPATH}`, so the removal manifest cannot be derived"
        )
    if kind != "blob":
        return None, (
            f"commit {commit} carries a {kind} at the install receipt path `{RC.RECEIPT_RELPATH}`, "
            "not a regular file, so the removal manifest cannot be derived; only a genuinely ABSENT "
            "receipt may fall back to the pre-receipt legacy list"
        )
    blob = _tree_blob(repo, commit, RC.RECEIPT_RELPATH)
    if blob is None:
        return None, (
            f"the install receipt `{RC.RECEIPT_RELPATH}` carried by commit {commit} cannot be read "
            "from this object database, so the removal manifest cannot be derived"
        )
    fd, tmp = tempfile.mkstemp(prefix=".idc-uninstall-receipt.", suffix=".yaml")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(blob)
        noise = io.StringIO()
        try:
            with contextlib.redirect_stderr(noise):        # `die` narrates to stderr; we re-report it
                _top, entries = RC.parse_receipt_document(tmp)
        except (Exception, SystemExit) as exc:  # noqa: BLE001 — any unparseable receipt fails closed
            detail = (noise.getvalue().strip() or str(exc)).splitlines()
            return None, (
                f"the install receipt `{RC.RECEIPT_RELPATH}` carried by commit {commit} does not "
                f"parse, so the removal manifest cannot be derived ({detail[-1] if detail else exc})"
            )
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    return entries, None


def _incomplete_removal_problem(repo: str, oid: str, parent: str) -> str | None:
    """None when `oid` removes the WHOLE IDC footprint its parent still carried, else what survived.

    This is what binds the witness to a genuinely completed `/idc:uninstall` rather than to any commit
    that merely drops the anchor (#202 review). Without it, a hand-made two-file commit deleting
    `docs/workflow/tracker-config.yaml` and `TRACKER.md` has the ungoverning shape while leaving every
    other IDC footprint in place — and its protected deletion would then be waved through the push
    gate forever after the next `/idc:init`.

    THE MANIFEST IS RE-DERIVED FROM THE PARENT TREE, never from the caller and never from the
    worktree: the parent is the last governed state, so it still carries both the receipt and the
    files the receipt lists. That keeps the answer identical at witness time and at every later push,
    which is the property the whole door rests on.

    AN OPERATOR-CUSTOMIZED FILE IS EXEMPT, BY BOTH OF THE TWO SIGNALS `/idc:uninstall` Phase 1 asks
    keep-or-remove on (defaulting to KEEPING, so either may legitimately survive the removal commit):
      * bytes in the parent tree that diverge from the stamped fingerprint (`modified` / `ask`), and
      * `state: customized` on the entry itself — what `/idc:update` stamps for a file the operator
        kept at its diff-and-ask. Its fingerprint is taken from those KEPT bytes, so it matches and
        would otherwise read as `unchanged` (`classify_receipt` grades by bytes alone and never reads
        `state`). Demanding its removal would refuse a genuine uninstall of any repo whose operator
        ever kept a scaffold file through an update.
    Only entries that are neither may a completed uninstall be required to have removed."""
    entries, problem = _receipt_entries_in_tree(repo, parent)
    if problem:
        return problem

    import idc_receipt_check as RC  # noqa: PLC0415 — lazy; the one canonical receipt parser

    runtime = "plus the runtime artifacts an applied uninstall always removes"
    if entries is None:
        source = f"the pre-receipt legacy owned-file list ({runtime})"
        required = set(C.LEGACY_UNINSTALL_OWNED_FILES)
    else:
        source = f"the install receipt carried by commit {parent} ({runtime})"
        # The receipt never lists ITSELF, and uninstall Phase 3c removes it with the anchor.
        required = {RC.RECEIPT_RELPATH}
        for entry in entries:
            rel = entry.get("path") or ""
            if entry.get("state") == "customized":
                continue    # operator-kept at update's diff-and-ask — uninstall asks, defaults to keep
            blob = _tree_blob(repo, parent, rel)
            if blob is None:
                continue    # gone before this commit, or no longer a plain file — either way what the
                            # parent carries is not the stamped bytes, so the divergence keep-signal
                            # below covers it and nothing is left for this commit to be required to remove
            if hashlib.sha256(blob).hexdigest() == entry.get("fingerprint"):
                required.add(rel)

    # THE SAME SET the uninstall closeout unions into its removal set (`_receipt_removal_set`), taken
    # from the one definition rather than copied (#202 review). `TRACKER.md` is runtime-created, so it
    # is deliberately absent from BOTH the receipt and the legacy list — yet an applied uninstall must
    # still remove it. Without this union a commit could delete the whole receipt-listed footprint and
    # the anchor, leave the tracker behind, and be witnessed as a completed uninstall anyway; its
    # protected deletions would then be exempt at every push the repository ever makes.
    required |= set(C.RUNTIME_UNINSTALL_ARTIFACTS)

    # Only what the parent actually CARRIED can be required: a manifest file that never existed there
    # (a runtime artifact never created, a footprint removed in an earlier commit) leaves nothing for
    # this commit to remove.
    survivors = [
        rel for rel in sorted(required) if _tree_has(repo, parent, rel) and _tree_has(repo, oid, rel)
    ]
    if not survivors:
        return None
    shown = ", ".join(f"`{rel}`" for rel in survivors[:5])
    if len(survivors) > 5:
        shown += f" (and {len(survivors) - 5} more)"
    return (
        f"commit {oid} is not a completed IDC uninstall: it drops the governance anchor but leaves "
        f"{len(survivors)} file(s) from {source} in place — {shown}. Run `/idc:uninstall`, which "
        "removes the whole receipt-derived footprint in one commit, rather than witnessing a partial "
        "removal"
    )


def uninstall_commit_problem(repo: str, commit: str) -> str | None:
    """None when `commit` has the sanctioned uninstall shape, else why it does not.

    THE SHAPE, re-derived from git every time and never read from any caller-supplied claim:
      * it resolves to exactly one commit with exactly ONE parent (a merge is not an uninstall);
      * its parent's tree HAS the governance anchor and its own tree does NOT — it is the commit that
        carries the repository out of IDC governance;
      * every protected machine surface it touches is touched by DELETION ONLY. Without this clause
        "delete the anchor" would be a universal key for writing machine-owned state in the same
        commit;
      * it REMOVES THE WHOLE FOOTPRINT its parent still carried, derived from the install receipt in
        the parent tree (or the fixed legacy list when that tree predates receipts) UNION the runtime
        artifacts neither of those lists names. This is the clause that binds the door to a completed
        `/idc:uninstall` instead of to any commit that happens to drop the anchor — see
        `_incomplete_removal_problem`.

    ORDER IS DELIBERATE: the cheap structural clauses answer first, so a near-miss is refused with
    the most specific reason available rather than with the manifest complaint."""
    try:
        oid = _run_git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}")
    except RuntimeError as exc:
        return f"`{commit}` does not resolve to a commit in this repository ({exc})"
    if not oid:
        return f"`{commit}` does not resolve to a commit in this repository"

    parents = _run_git(repo, "rev-list", "--parents", "-n", "1", oid).split()[1:]
    if len(parents) != 1:
        return (
            f"commit {oid} has {len(parents)} parent(s); the uninstall removal commit is a single "
            "ordinary commit on top of the governed history"
        )
    parent = parents[0]

    if not _tree_has(repo, parent, PG.GOVERNANCE_ANCHOR_RELPATH):
        return (
            f"commit {oid} is not the ungoverning commit: its parent does not carry the governance "
            f"anchor `{PG.GOVERNANCE_ANCHOR_RELPATH}`, so this commit cannot be the one that removes it"
        )
    if _tree_has(repo, oid, PG.GOVERNANCE_ANCHOR_RELPATH):
        return (
            f"commit {oid} is not the ungoverning commit: it leaves the governance anchor "
            f"`{PG.GOVERNANCE_ANCHOR_RELPATH}` in place, so the repository stays IDC-governed"
        )

    for status, rel in _commit_name_status(repo, oid):
        if PG.is_protected_machine_surface(rel) and status != "D":
            return (
                f"commit {oid} does not only REMOVE machine-owned state: it applies `{status}` to the "
                f"protected surface `{rel}`"
            )
    return _incomplete_removal_problem(repo, oid, parent)


def _exempt_witnessed_uninstall_paths(
    repo: str, commits: list[tuple[str, list[str]]]
) -> list[str]:
    """Flatten the outgoing commits into the gated path set, dropping ONLY the protected deletions of
    commits that are both witnessed and still shape-verified.

    Everything else in an exempted commit — its ordinary paths — stays in the gated set and is still
    judged against the live authorization boundary, so the exemption removes exactly the part no
    authorization could ever cover and nothing more.

    A commit that merely RECORDS an append-only machine log (adds/modifies the transition journal) is
    exempted for that path too, witness or not — the push-side twin of `_drop_recorded_machine_state`,
    which documents why and why the family is deliberately narrow. Removals still need the witness, so
    the uninstall door is unchanged, and every other protected surface stays gated."""
    witnessed = PG.read_uninstall_witness(repo)
    paths: list[str] = []
    seen: set[str] = set()
    for commit, rels in commits:
        exempt: set[str] = set()
        if commit.lower() in witnessed and uninstall_commit_problem(repo, commit) is None:
            exempt = {rel for rel in rels if PG.is_protected_machine_surface(rel)}
        elif any(PG.is_recordable_machine_log(rel) for rel in rels):
            # Recorded (never removed) machine logs, attributed per commit like everything else here:
            # a path this commit only adds/modifies is exempt, while the SAME path deleted by another
            # outgoing commit still reaches the gate. The status re-read costs one `diff-tree`, so it
            # runs ONLY for the commits that actually carry a log path — the vast majority of a push
            # never touches one and pays nothing.
            try:
                records = _commit_name_status(repo, commit)
            except RuntimeError:
                records = []          # cannot attribute statuses → gate every path (fail closed)
            recorded = {rel for status, rel in records if status in _RECORDED_STATUSES}
            removed = {rel for status, rel in records if status not in _RECORDED_STATUSES}
            exempt = {
                rel for rel in rels
                if rel in recorded and rel not in removed and PG.is_recordable_machine_log(rel)
            }
        for rel in rels:
            if rel in exempt or rel in seen:
                continue
            seen.add(rel)
            paths.append(rel)
    return paths


def _gate(repo: str, plugin_root: str, action: str, paths: list[str]) -> dict[str, object]:
    # V-AUTH stage 3: echo the live authorization's ticket/graph-node identity into the request —
    # the shared gate now REQUIRES it. This backstop is Codex's per-tool coverage path (Codex runs no
    # per-tool hook), so the echo here is what keeps sanctioned Codex commits/pushes admissible
    # under the identity-required gate.
    request: dict[str, object] = {"action": action, "paths": paths}
    request.update(PG.request_identity(_repo_root(repo)))
    return PG.evaluate_request(_repo_root(repo), plugin_root, request)


def _gate_exit(decision: dict[str, object]) -> int:
    observe = decision.get("observe")
    if isinstance(observe, str) and observe:
        print(f"IDC Path Gate observe (would deny): {observe}", file=sys.stderr)
    if decision.get("allowed"):
        return 0
    print(str(decision.get("reason") or "IDC Path Gate denied the git mutation"), file=sys.stderr)
    return 1


def cmd_install(args: argparse.Namespace) -> int:
    install_hooks(args.repo, args.plugin_root)
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    ok, detail = verify_hooks(args.repo, args.plugin_root)
    if ok:
        return 0
    print(f"IDC Path Gate git hook verification failed: {detail}", file=sys.stderr)
    return 2


def cmd_pre_commit(args: argparse.Namespace) -> int:
    repo = _repo_root(args.repo)
    paths = _collect_pre_commit_paths(repo)
    if not paths:
        return 0
    return _gate_exit(_gate(repo, args.plugin_root, "git", paths))


def cmd_pre_push(args: argparse.Namespace) -> int:
    repo = _repo_root(args.repo)
    commits = _collect_pre_push_commits(repo, sys.stdin.read().splitlines(), remote=args.remote)
    paths = _exempt_witnessed_uninstall_paths(repo, commits)
    if not paths:
        return 0
    return _gate_exit(_gate(repo, args.plugin_root, "git", paths))


def cmd_witness_uninstall(args: argparse.Namespace) -> int:
    """The sanctioned uninstall push door: prove the shape, then record the commit.

    Called from the `/idc:uninstall` playbook — Phase 3c right after it lands the removal commit, and
    its recovery section for a repository an older plugin version already stranded. Both are COMMAND
    paths; the operator is never told to run this helper by hand (AGENTS.md: the `scripts/idc_*.py`
    helpers are called by the commands). It is safe to point at any commit: anything that is not a
    completed uninstall is refused here AND, independently, at push."""
    repo = _repo_root(args.repo)
    problem = uninstall_commit_problem(repo, args.commit)
    if problem:
        print(
            "IDC Path Gate refused to witness this commit as an IDC uninstall removal: " + problem,
            file=sys.stderr,
        )
        return 1
    oid = _run_git(repo, "rev-parse", "--verify", f"{args.commit}^{{commit}}")
    PG.record_uninstall_commit(repo, oid)
    print(f"IDC Path Gate: witnessed uninstall removal commit {oid}; it is now publishable.")
    return 0


# How long a single read-only network probe may take before the diagnosis gives up and reports
# INDETERMINATE. Doctor must never hang: a slow or unreachable remote has to become an honest "could
# not determine", not a wedged command.
AUDIT_REMOTE_TIMEOUT_S = 20


def _ls_remote_bounded(repo: str, remote: str, ref: str):
    """`git ls-remote` under a hard timeout with EVERY interactive prompt disabled, or None.

    Unbounded, this is the one call in the audit that can block forever: an unreachable host at the
    TCP layer, or git/ssh waiting on a credential or host-key prompt with nobody there to answer.
    `/idc:doctor` would hang instead of returning its documented SKIP. None means "could not answer",
    which the caller maps to INDETERMINATE — never to a clean range."""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"        # no username/password prompt
    env["GIT_ASKPASS"] = "echo"             # no GUI/askpass helper
    env.setdefault("GIT_SSH_COMMAND",
                   "ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new -oConnectTimeout=10")
    try:
        proc = subprocess.run(
            ["git", "-C", repo, "ls-remote", "--refs", remote, ref],
            capture_output=True, text=True, env=env, timeout=AUDIT_REMOTE_TIMEOUT_S,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def _outgoing_push_lines(repo: str, remote: str) -> list[str]:
    """Synthesize the pre-push stdin lines git would feed for `HEAD -> <remote>/<branch>`.

    Read-only. Mirrors the range derivation `commands/uninstall.md`'s recovery section documents:
    what the remote already has for THIS ref, or — when the ref is new there — the empty sha, which
    `_collect_pre_push_commits` already expands into "everything the remote has on ANY ref". Returns
    [] when there is no branch or the remote cannot be listed, so the caller reports rather than
    guesses."""
    try:
        branch = _run_git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
        head = _run_git(repo, "rev-parse", "HEAD")
    except RuntimeError:
        return []
    if not branch or not head:
        return []
    remote_sha = ""
    try:
        out = _ls_remote_bounded(repo, remote, f"refs/heads/{branch}")
        if out is None:
            return []
        if out.strip():
            remote_sha = out.split()[0]
    except RuntimeError:
        return []
    zero = "0" * 40
    return [f"refs/heads/{branch} {head} refs/heads/{branch} {remote_sha or zero}"]


def audit_outgoing(repo: str, plugin_root: str, remote: str) -> dict[str, object]:
    """Would a push of the current branch be REFUSED by the pre-push path gate? Read-only (#203).

    Walks the unpublished range through the SAME code path the hook uses — `_collect_pre_push_commits`
    -> `_exempt_witnessed_uninstall_paths` -> `_gate` — so the diagnosis can never disagree with the
    thing that actually refuses. Nothing is written and no witness is recorded.

    The value is naming the condition BEFORE the operator hits it. A repo stranded by a pre-#202
    uninstall (its removal commit sitting unwitnessed in the outgoing range) is indistinguishable
    from a healthy repo until a push fails with a path-gate refusal that reads as if the CURRENT
    change were at fault. So when a refusal is predicted, the unwitnessed-but-genuine uninstall
    removal commits are named separately from everything else, because they have their OWN sanctioned
    recovery door and the rest do not."""
    result: dict[str, object] = {
        "status": "ok", "remote": remote, "reason": "", "recoverable_uninstall_commits": [],
    }
    lines = _outgoing_push_lines(repo, remote)
    if not lines:
        result["status"] = "indeterminate"
        result["reason"] = (
            f"could not derive the unpublished range for remote {remote!r} (no branch, no such "
            "remote, or it is unreachable) — publishability is unknown, not proven")
        return result
    commits = _collect_pre_push_commits(repo, lines, remote=remote)
    if not commits:
        result["reason"] = "nothing to publish — the remote already has this branch's commits"
        return result
    paths = _exempt_witnessed_uninstall_paths(repo, commits)
    if not paths:
        result["reason"] = f"{len(commits)} unpublished commit(s), none touching a gated path"
        return result
    decision = _gate(repo, plugin_root, "git", paths)
    if decision.get("allowed"):
        result["reason"] = f"{len(commits)} unpublished commit(s), all admissible"
        return result
    result["status"] = "would-refuse"
    result["reason"] = str(decision.get("reason") or "the Path Gate would deny this push")
    # A genuine, still-unwitnessed uninstall removal commit is the recoverable case: it has a
    # sanctioned door. Anything else is ordinary path-gate guidance.
    witnessed = PG.read_uninstall_witness(repo)
    recoverable = [
        commit for commit, _ in commits
        if commit.lower() not in witnessed and uninstall_commit_problem(repo, commit) is None
    ]
    result["recoverable_uninstall_commits"] = recoverable
    return result


def cmd_audit_outgoing(args: argparse.Namespace) -> int:
    """0 = publishable, 1 = a push would be refused, 2 = indeterminate (fail-closed for a diagnosis:
    'we could not tell' must never print as 'fine')."""
    repo = _repo_root(args.repo)
    verdict = audit_outgoing(repo, args.plugin_root, args.remote)
    if args.json:
        print(json.dumps(verdict, indent=2, sort_keys=True))
    else:
        print(f"outgoing-range: {verdict['status']} — {verdict['reason']}")
        # The remediation is meant to be RUN, so emit a real path — a literal `<plugin>` placeholder
        # is parsed by the shell as a redirection and the sanctioned repair fails. Both operands are
        # shell-quoted because a repo path may contain spaces.
        door = os.path.join(os.path.abspath(args.plugin_root), "scripts", "idc_git_path_gate.py")
        for commit in verdict.get("recoverable_uninstall_commits") or []:
            print(f"  recoverable: {commit} is a completed IDC uninstall removal commit with no "
                  f"witness; witness it, then push:")
            print(f"    python3 {shlex.quote(door)} witness-uninstall "
                  f"--repo {shlex.quote(repo)} --commit {commit}")
    return {"ok": 0, "would-refuse": 1}.get(str(verdict["status"]), 2)


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="op", required=True)

    p = sub.add_parser("install-hooks")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_install)

    p = sub.add_parser("verify-hooks")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("pre-commit")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_pre_commit)

    p = sub.add_parser("pre-push")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.add_argument("--remote")
    p.set_defaults(func=cmd_pre_push)

    p = sub.add_parser(
        "witness-uninstall",
        help="record an IDC uninstall removal commit so it can be pushed (shape-verified)",
    )
    p.add_argument("--repo", required=True)
    p.add_argument("--commit", required=True)
    p.set_defaults(func=cmd_witness_uninstall)

    p = sub.add_parser(
        "audit-outgoing",
        help="read-only: would a push of this branch be refused by the pre-push path gate? (#203)",
    )
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.add_argument("--remote", default="origin")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_audit_outgoing)

    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:  # noqa: BLE001
        print(f"IDC Path Gate git helper failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
