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


def contract_script(plugin_root):
    """The REAL absolute path to idc_command_contract.py under the plugin root a gate was handed.
    `${CLAUDE_PLUGIN_ROOT}` is a markdown-only substitution — it is NOT a shell/Python env var, so a
    Python-emitted literal would resolve to the broken `/scripts/idc_command_contract.py`. Gates
    receive the real root as argv[1] and join it here, so every remediation they print is runnable
    as-is."""
    return os.path.join(plugin_root or "", "scripts", "idc_command_contract.py")


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


def scrub(text):
    """THE hook-side door for text a CHILD PROCESS produced — delegates to the shared credential
    table's machine-output profile (`scripts/idc_credential_shapes.py`).

    WHY IT LIVES HERE RATHER THAN BEING IMPORTED PER HOOK. Hooks sit one directory below the table
    and must never brick the user's session, so each one importing it directly would mean either a
    hard import that can fail at hook time or the same six-line fail-closed wrapper copied into every
    gate — which is exactly the drift the shared table was created to end. One wrapper, here, beside
    the other shared fail modes.

    FAIL CLOSED, and note this is the ONE fail mode in this module that does not fail OPEN: an
    unloadable table means the text cannot be vouched for, and a withheld diagnostic costs a re-run
    by hand while an unscrubbed one costs a credential rotation."""
    if not text:
        return text
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        import idc_credential_shapes as CS  # noqa: E402
    except ImportError:
        return "[child output withheld — the credential-shape table could not be loaded]"
    return CS.scrub(text)


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
#                               the action still proceeds through the normal flow. The interlock uses
#                               this OUTSIDE an active /idc:* command, so ordinary governed-repo work
#                               is never bricked (§6 over-blocking).
#   * pre_tool_deny(reason)   — HARD DENY: emit permissionDecision=deny with the remediation as the
#                               reason (Claude Code feeds it back to the model → self-healing denial).
#                               Honors IDC_HOOKS_OBSERVE_ONLY=1 → downgrade to warn-inject (§6).
# POSTURE (Task 3): the interlock HARD-DENIES while the session owns an ACTIVE /idc:* command (the
# window where a raw mutation is the forbidden improvisation) and WARN-INJECTS otherwise; there is no
# opt-in promotion step — the active-command deny is the shipped enforcement. IDC_HOOKS_OBSERVE_ONLY=1
# is the one debug escape (downgrades any deny back to warn-inject).
def pre_tool_allow():
    """Proceed: emit nothing, exit 0. The normal permission flow is untouched."""
    sys.exit(0)


def pre_tool_warn(reason):
    """Warn-inject: surface the remediation (stderr) but make NO permission decision, so the action
    still proceeds. The non-bricking posture the interlock uses OUTSIDE an active /idc:* command. NOTE:
    exit-0 stderr is transcript/telemetry only — it is NOT injected into the model context; the
    model-visible self-heal is the active-command pre_tool_deny()."""
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


# ── transient-sidecar plumbing (the ONE copy, shared by every .idc-*.json sidecar) ─────────────────
# IDC keeps several local, gitignored per-session sidecars — the obligations ledger, the drain verdict,
# the command reports, the pause record. Each one needs the same two things, and each one had grown its
# own copy of both: an ATOMIC JSON write, and an IDEMPOTENT non-destructive `.gitignore` append. Four
# copies is four chances to drift, and they HAD drifted — the newest copy silently dropped the
# "existing file already ends in a comment or a colon" branch below, so it appended a provenance
# comment where its three siblings deliberately do not.
#
# Both helpers live here because all four sidecars already import this module for `is_governed_repo`,
# so sharing them adds no new dependency edge to anything.


def atomic_write_json(path, payload, *, prefix, label) -> bool:
    """Write `payload` as JSON to `path` atomically (temp file in the SAME directory + `os.replace`),
    so a concurrent reader never observes a half-written sidecar.

    BEST-EFFORT BY CONTRACT: every failure warns and returns False, and NOTHING here raises. These
    sidecars are written on paths that must not be breakable by their own bookkeeping — the drain
    persists its verdict just before exiting, the pause record is written mid-command — so a full disk
    must degrade to "not persisted", never to a traceback that takes the real work down with it.
    Returns True only after the replacement has actually landed; callers that must not report success
    on a write that did not happen (the pause record) key off exactly that.

    `prefix` names the temp file so a stray `.tmp` is traceable to its writer; `label` prefixes the
    warning so an operator can tell which sidecar complained."""
    d = os.path.dirname(path) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=prefix, suffix=".tmp")
    except OSError as e:
        warn(f"{label}: cannot create temp file in {d}: {e}")
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        return True
    except OSError as e:
        warn(f"{label}: atomic write to {path} failed: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def ensure_gitignored(repo_root, line, *, created_comment, appended_comment, label) -> bool:
    """Ensure the repo-root `.gitignore` contains `line`, idempotently and NON-DESTRUCTIVELY.

    Creates the file if absent; otherwise APPENDS only when the line is missing — it never rewrites,
    reorders, or deduplicates an operator's existing lines. The presence test is whole-line and
    whitespace-tolerant, so an entry that is already there in any formatting is left alone.

    REPO-GATED: a no-op returning False outside an IDC-governed repo, so a stray call can never create
    a `.gitignore` in a directory that is none of IDC's business. Returns True iff the line is present
    afterward.

    THE COMMENT RULE, which is the part that had drifted. A fresh file gets `created_comment` (it is
    ours entirely, so it should say what it is for). An EXISTING file gets `appended_comment` only when
    it does not already end in a comment or a `:` — appending a provenance header directly under
    someone else's section heading reads as though our entry belongs to their section. One of the four
    copies of this function had lost that branch."""
    if not is_governed_repo(repo_root):
        return False
    gi = os.path.join(repo_root, ".gitignore")
    try:
        existing = ""
        if os.path.isfile(gi):
            with open(gi, encoding="utf-8") as fh:
                existing = fh.read()
        if any(ln.strip() == line for ln in existing.splitlines()):
            return True
        with open(gi, "a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            if not existing:
                fh.write(created_comment + "\n")
            elif not existing.rstrip("\n").endswith(("#", ":")):
                fh.write(appended_comment + "\n")
            fh.write(line + "\n")
        return True
    except OSError as e:
        warn(f"{label}: could not ensure .gitignore in {repo_root}: {e}")
        return False
