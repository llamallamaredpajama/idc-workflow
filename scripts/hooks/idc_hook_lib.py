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
    interlocks (§3.2) deny via a DIFFERENT shape (`hookSpecificOutput.permissionDecision`) — see
    pre_tool_deny() below. This primitive stays the STOP-FAMILY deny; the interlock gate uses the
    PreToolUse-family functions so no gate retrofits the wrong schema onto the wrong event.
    """
    if observe_only():
        warn(f"OBSERVE-ONLY (would block): {reason}")
        sys.exit(0)
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


# ── UserPromptExpansion family (the command entry gate, Task 2 — command integrity) ───────────────
# A UserPromptExpansion hook decides whether a `/idc:*` command is allowed to expand into its body,
# BEFORE the command runs. Two model-visible postures (both exit 0 — a hook signals via its JSON):
#   * prompt_expansion_block(reason)   — REFUSE the expansion; `reason` is surfaced to the model.
#   * prompt_expansion_context(context) — ALLOW + inject `context` alongside the expanded command.
# The gate's observe-only downgrade is applied at the gate (it wraps block in its own observe check),
# so these primitives stay minimal — the exact shape Claude Code's UserPromptExpansion contract expects.
def prompt_expansion_block(reason):
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}))
    raise SystemExit(0)


def prompt_expansion_context(context):
    sys.stdout.write(json.dumps({"additionalContext": context}))
    raise SystemExit(0)


# ── PreToolUse family (the terminal-action interlocks, v4 Phase 2 §3.2) ───────────────────────────
# A PreToolUse gate decides on a tool call BEFORE it runs. Three postures, all exit 0 (a hook signals
# via its JSON, not its exit code):
#   * pre_tool_allow()        — say nothing; the normal permission flow proceeds (the hot path).
#   * pre_tool_warn(reason)   — WARN-INJECT: surface the remediation on stderr but DO NOT decide, so
#                               the action still proceeds through the normal flow. This is the SHIPPED
#                               rollout posture — it can never brick a real workflow (§6 over-blocking).
#   * pre_tool_deny(reason)   — HARD DENY: emit permissionDecision=deny with the remediation as the
#                               reason (Claude Code feeds it back to the model → self-healing denial).
#                               Honors IDC_HOOKS_OBSERVE_ONLY=1 → downgrade to warn-inject (§6).
# Deny is the PROMOTED posture (a later operator decision, §6 decision 1); warn-inject ships first.
def pre_tool_allow():
    """Proceed: emit nothing, exit 0. The normal permission flow is untouched."""
    sys.exit(0)


def pre_tool_warn(reason):
    """Warn-inject: surface the remediation (stderr) but make NO permission decision, so the action
    still proceeds. The shipped, non-bricking rollout posture. NOTE: exit-0 stderr is transcript/
    telemetry only — it is NOT injected into the model context (the observe-first phase); the
    model-visible self-heal is pre_tool_deny()."""
    warn(reason)
    sys.exit(0)


def pre_tool_deny(reason):
    """Hard-deny the PreToolUse tool call with a remediation `reason`. Downgrades to warn-inject when
    IDC_HOOKS_OBSERVE_ONLY=1 (the operator debug escape)."""
    if observe_only():
        warn(f"OBSERVE-ONLY (would deny): {reason}")
        sys.exit(0)
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def guard_pre_tool(fn):
    """Run a PreToolUse gate `fn(payload, plugin_root)`. Policy decisions happen inside `fn` via
    pre_tool_warn()/pre_tool_deny()/pre_tool_allow(); an UNEXPECTED exception fails OPEN (allow) —
    a gate bug must never block a tool call — unless IDC_HOOKS_STRICT=1 (then it denies, to surface
    the bug hard in CI/e2e). Mirrors guard_pre_action's fail mode for the PreToolUse family."""
    plugin_root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    payload = read_payload()
    try:
        fn(payload, plugin_root)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — infra bug, not a policy decision
        if strict():
            pre_tool_deny(f"idc interlock gate errored (STRICT): {e}")
        warn(f"interlock gate errored, failing open (allow): {e}")
        sys.exit(0)
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


# ── PostToolUse family (fail-OPEN, ALWAYS — v4 Phase 3 Stage D, first consumer) ───────────────────
# A PostToolUse hook reacts to a tool call that ALREADY RAN — there is nothing left to deny, only to
# repair or remind. Per the P4 fail-mode contract (module docstring): a post-hoc observer is fail-OPEN
# ALWAYS, unlike guard_pre_tool/guard_pre_action which fail closed under IDC_HOOKS_STRICT=1. STRICT
# still surfaces an internal error LOUDLY on stderr here (so a real bug in the observer is visible in
# CI/e2e), but it NEVER changes the exit code or emits a block decision — a PostToolUse hook must never
# break the user's command, full stop.
#
# Output contract (verified against the Claude Code hooks reference, docs/en/hooks.md, 2026-07-05):
#   * post_tool_allow()      — say nothing, exit 0. The hot path (no drift found / nothing to check).
#   * post_tool_inject(ctx)  — emit {"hookSpecificOutput": {"hookEventName": "PostToolUse",
#                              "additionalContext": ctx}} on stdout, exit 0. This is model-visible
#                              context injected next to the tool result — NEVER `{"decision":"block"}`
#                              (PostToolUse DOES support decision:"block", but that halts further
#                              processing after a command already ran — exactly the "breaks the user's
#                              command" outcome a fail-open observer must never cause, so no helper
#                              here ever emits it).
def post_tool_allow():
    """Nothing to report: emit nothing, exit 0. The tool result is untouched."""
    sys.exit(0)


def post_tool_inject(context):
    """Inject `context` as model-visible additionalContext next to the tool result. Fail-open by
    construction: this NEVER emits a decision/block — a post-hoc observer only ever informs, never
    breaks the command that already ran."""
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": context,
        }
    }))
    sys.exit(0)


def guard_post_observer(fn):
    """Run a PostToolUse observer `fn(payload, plugin_root)`. `fn` reports via
    post_tool_inject()/post_tool_allow() (or simply `return`s, which is the same as post_tool_allow()).
    ALWAYS fails open — an unexpected exception here warns and exits 0, EVEN UNDER IDC_HOOKS_STRICT=1
    (unlike guard_pre_tool/guard_pre_action): a post-hoc observer has nothing left to protect by
    blocking, since the tool call it is reacting to already completed. STRICT only makes the warning
    louder (surfaced distinctly on stderr) so a real observer bug is not silently invisible in CI/e2e —
    it never flips this to a block or a non-zero exit."""
    plugin_root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    payload = read_payload()
    try:
        fn(payload, plugin_root)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — infra bug, never a reason to touch the command's outcome
        if strict():
            warn(f"post-observer errored (STRICT — surfaced, still fail-open/allow): {e}")
        else:
            warn(f"post-observer errored, failing open (allow, no context injected): {e}")
        sys.exit(0)
    # fn should have called post_tool_inject()/post_tool_allow(), or simply returned (== allow).
    sys.exit(0)
