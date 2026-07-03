"""idc_hook_lib.py — the shared P4 fail-mode + plumbing helper for IDC's hook gates (v4 §3.2).

Every IDC hook script (SubagentStop verdict gate now; PreToolUse interlocks + the Stop fixpoint
gate in later phases) shares this module so the fail modes, repo-gating, the observe-only escape
hatch, the block/allow output contract, and the bounded anti-nag counter are DEFINED ONCE (plan
P4: "Defined once, shared by all gates").

P4 fail mode (Phase 1): `guard_pre_action(fn)` — a PRE-action gate (blocks a stop/tool). The gate's
*deliberate* policy decision (e.g. "no valid verdict") is a real block via block(). An *unexpected
exception* inside the gate is an infrastructure bug, NOT a policy denial: per the §6 rollout
discipline ("fail-soft, observability-first where denial isn't proven safe") it fails OPEN — warn
loudly and allow — so a gate bug can never brick the workflow. Set IDC_HOOKS_STRICT=1 to fail closed
on such bugs instead (surfaces them hard in CI/e2e). (The post-hoc-observer fail mode — PostToolUse
side-band, always fail-open — lands with its first consumer in a later phase.)

Escape hatch: IDC_HOOKS_OBSERVE_ONLY=1 downgrades every would-be block to a stderr warning
(rollout: observe first, deny later). Honored by block().
"""
import json
import os
import re
import sys
import tempfile

REVIEW_AGENT_TYPES = {"idc-review-agent", "idc-review-coordinator"}
DEFAULT_BOUND = 3  # N=3 bounded re-ask (plan §3.2)


def read_payload():
    """The hook's stdin JSON payload as a dict (empty dict if stdin is empty/garbage)."""
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except (ValueError, OSError):
        return {}


def iter_transcript_events(path):
    """Yield each decoded JSONL event from a session/agent transcript, skipping blank/garbage lines.
    One hardened reader shared by every transcript-reading gate (the verdict gate now; the Stop
    fixpoint gate later) so none re-derives the `for line → strip → json.loads` skeleton."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def is_governed_repo(cwd):
    """True iff `cwd` is an IDC-governed repo — the same gate the SessionEnd sweep wrapper uses
    (docs/workflow/tracker-config.yaml present). Hooks fire for every session on the machine, so
    this repo-gate is what makes them no-ops everywhere else."""
    try:
        return os.path.isfile(os.path.join(cwd or ".", "docs", "workflow", "tracker-config.yaml"))
    except OSError:
        return False


def observe_only():
    return os.environ.get("IDC_HOOKS_OBSERVE_ONLY", "") == "1"


def strict():
    return os.environ.get("IDC_HOOKS_STRICT", "") == "1"


def normalize_agent_type(agent_type):
    """Strip the harness `idc:` namespace prefix so a gate can match `idc-review-agent`
    whether the payload carries `idc:idc-review-agent` or the bare flat name."""
    t = (agent_type or "").strip()
    return t[4:] if t.startswith("idc:") else t


def allow():
    """Allow the stop/action: emit nothing, exit 0. (Stop/SubagentStop hooks allow by default.)"""
    sys.exit(0)


def warn(msg):
    sys.stderr.write(f"[idc-hook] {msg}\n")


def loud_fail(msg):
    """The bounded gate gave up after N tries — announce it loudly (P8: a governance miss is a
    harness signal, make it visible) but ALLOW the stop so the session is never infinitely nagged."""
    bar = "!" * 72
    sys.stderr.write(f"\n{bar}\n[idc-hook] LOUD-FAIL (bound exhausted): {msg}\n{bar}\n")


def block(reason):
    """Deny the stop/action with a remediation `reason` the model acts on. Honors the observe-only
    escape hatch (downgrades to a warning + allow).

    NOTE: this emits the Stop/SubagentStop-family schema (`{"decision":"block", ...}`). PreToolUse
    interlocks (a later phase) deny via a different shape (`hookSpecificOutput.permissionDecision`),
    so this primitive is shared across the STOP-FAMILY gates today; the interlock phase makes it
    event-aware rather than retrofitting the Stop shape onto PreToolUse.
    """
    if observe_only():
        warn(f"OBSERVE-ONLY (would block): {reason}")
        sys.exit(0)
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


# ── bounded anti-nag counter (session+agent scoped, per-user temp dir) ───────────────────────────
def _counter_path(key):
    d = os.path.join(tempfile.gettempdir(), "idc-hook-state")
    os.makedirs(d, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", key)
    return os.path.join(d, safe + ".ctr")


def counter_get(key):
    try:
        with open(_counter_path(key), encoding="utf-8") as fh:
            return int(fh.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def counter_set(key, n):
    try:
        with open(_counter_path(key), "w", encoding="utf-8") as fh:
            fh.write(str(n))
    except OSError:
        pass


def counter_clear(key):
    try:
        os.remove(_counter_path(key))
    except OSError:
        pass


def bounded_block(key, reason, bound=DEFAULT_BOUND):
    """Block up to `bound` times for `key`, then loud-fail-allow. The anti-nag contract: a gate can
    never block forever. `stop_hook_active` in the payload is Claude Code's own backstop; this
    counter is the primary, deterministic bound."""
    n = counter_get(key)
    if observe_only():
        warn(f"OBSERVE-ONLY (would block): {reason}")
        sys.exit(0)
    if n >= bound:
        counter_clear(key)
        loud_fail(reason)
        sys.exit(0)
    counter_set(key, n + 1)
    block(reason)


def guard_pre_action(fn):
    """Run a pre-action gate `fn(payload, plugin_root)`. Policy denials happen inside `fn` via
    block()/bounded_block(); an UNEXPECTED exception fails open (warn + allow) unless STRICT."""
    plugin_root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    payload = read_payload()
    try:
        fn(payload, plugin_root)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — infra bug, not a policy denial
        if strict():
            block(f"idc hook gate errored (STRICT): {e}")
        warn(f"gate errored, failing open (allow): {e}")
        sys.exit(0)
    # fn should have called allow()/block(); default-allow if it returned.
    sys.exit(0)
