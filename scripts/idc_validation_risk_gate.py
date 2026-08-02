#!/usr/bin/env python3
"""Deterministic risk-gated divergent discovery / adversarial falsification for Plan.

The helper never authors tracker state or mutates the frozen gate. It only decides whether a ticket's
risk inputs require the bounded read-only divergent/falsification pass, validates the exact branch
schema, enforces the exact skeptic question, discards any gate defeated by a majority, and echoes the
fixed validator/frozen-gate/path/attempt inputs back unchanged so callers can prove discovery never
rewrote them.

THE GATE IS AUTHORITATIVE OVER ITS OWN REQUIREDNESS (F59). It used to answer
`required = bool(risk_inputs)` where `risk_inputs` was purely the caller's repeatable `--risk-input`
flag: omit every flag and the gate returned `required: false`, exit 0, without ever looking at the
touch set, the dependency delta, or anything else about the contract. Adversarial falsification was
therefore satisfied by simply not asking for it, which makes the thing bookkeeping rather than a
gate. So requiredness is now the union of

  * DECLARED   — what the caller passed via `--risk-input`, still honored; and
  * DERIVED    — what FIXED CODE reads out of THE TOUCH SET IT IS GIVEN (`--touch`, and the baseline
                 classification when `--baseline` is supplied) — the same set the validation contract
                 will later freeze. `touch` is a fact about the change, not a request for a verdict:
                 the caller supplies it, fixed code alone decides what risk it carries.

A caller can add risk but can no longer subtract it, and when the derived set is non-empty the gate
refuses (exit 2) unless a real falsification scenario is supplied. The output reports the two sets
separately, plus a `derivation` block naming exactly which risk dimensions fixed code can decide and
which remain declaration-only — so `required: false` can never be read as "fixed code inspected
everything and found nothing".

SCOPE OF THE GUARANTEE — stated exactly, because overclaiming it is itself the defect this paragraph
corrects (F64). GUARANTEED here: on a given touch set, falsification can no longer be skipped by
simply not asking for it; declaring `--risk-input` can only ADD to what fixed code derives. What
this helper alone still cannot enforce — `--touch` is a plain repeatable flag at this call site, so
nothing IN THIS PROCESS binds the judged touch set to anything — is now enforced at the freeze door
instead (F64 closure): the result carries a `result_digest` over its own canonical JSON, and
`idc_validation_contract.py freeze --risk-gate-result <file>` verifies that digest, requires the
result's touch set and baseline to EQUAL the ones being frozen, requires everything fixed code
derives from the frozen facts to appear in the result's risk inputs, and embeds the digest inside
the digest-bound contract — while a freeze whose touch set carries fixed-code-derived risk REFUSES
outright when no result is supplied. Narrowing `--touch` at THIS call site therefore no longer
narrows what the freeze demands: the freeze derives from its own frozen touch set and refuses a
result judged on a different one. What remains a caller choice is running this gate on facts nothing
ever freezes (a scratch invocation binds nothing and proves nothing — only the freeze-bound result
counts).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ALLOWED_RISK_INPUTS = [
    "security-sensitive-path",
    "cross-cutting-surface",
    "new-runtime-dependency",
    "expected-green-baseline",
    "large-touch-set",
]
SKEPTIC_QUESTION = "show how this check passes while the goal is actually broken"
CANDIDATE_KEYS = ["promise", "failure_mode", "observable_evidence", "executable_check"]

# --- the fixed derivation table (F59) --------------------------------------------------------------
# Every threshold and marker below is FIXED CODE, deliberately boring and greppable: a reviewer must
# be able to read what the gate will decide without running it, and a caller must not be able to
# argue with it. Widening any of these is a deliberate edit here, not a call-site choice.

# `large-touch-set`: the frozen contract names at least this many touch entries.
LARGE_TOUCH_SET_MIN = 5

# `cross-cutting-surface`: the touch set spans at least this many distinct top-level path segments.
CROSS_CUTTING_MIN_ROOTS = 3

# `new-runtime-dependency`: the touch set names a dependency manifest / lockfile. Basename match, so
# `services/api/package.json` counts exactly like a root-level one.
DEPENDENCY_MANIFESTS = frozenset({
    "requirements.txt", "requirements-dev.txt", "constraints.txt", "pyproject.toml", "setup.py",
    "setup.cfg", "pipfile", "pipfile.lock", "poetry.lock", "uv.lock",
    "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json",
    "go.mod", "go.sum", "cargo.toml", "cargo.lock", "gemfile", "gemfile.lock", "composer.json",
    "composer.lock", "pom.xml", "build.gradle", "build.gradle.kts", "mix.exs", "pubspec.yaml",
    "podfile", "podfile.lock", "package.swift",
})

# `security-sensitive-path`: substrings that mark a touched path as security-bearing. Matched
# case-insensitively against the whole normalized entry, so a directory or a file both hit.
SECURITY_SENSITIVE_MARKERS = (
    ".github/", ".git/hooks", "hooks/", "codeowners", "ruleset",
    "auth", "secret", "credential", "token", "password", "passwd", "privkey", "private-key",
    "crypto", "cipher", "certificate", "keystore", "security", "permission", "privilege",
    "sudo", "iam", "acl", "sandbox", "sanitiz", "escap", "session",
    ".env", ".pem", ".key", ".p12", ".pfx", "id_rsa",
)

# The baseline classifications the frozen contract distinguishes. `expected-green` is a risk input by
# name: a contract that expects an already-green baseline is the one whose verification can pass
# without ever having proven anything.
BASELINE_CHOICES = ("expected-red", "expected-green", "unknown")
BASELINE_RISK = "expected-green-baseline"

# Which of the five named risk inputs FIXED CODE can decide from the contract facts this helper
# receives, and which stay declaration-only. Reported verbatim in the output so nobody over-reads a
# `required: false`.
DERIVABLE_RISK_INPUTS = (
    "security-sensitive-path",
    "cross-cutting-surface",
    "new-runtime-dependency",
    "large-touch-set",
)
BASELINE_DERIVED_WHEN = "--baseline is supplied (declaration-only otherwise)"


class RiskGateError(Exception):
    pass


def result_digest(doc: dict) -> str:
    """The canonical digest of a risk-gate result: sha256 over the sorted-key JSON of everything in
    `doc` EXCEPT the `result_digest` field itself. One function, used both to STAMP the result at
    `evaluate` and to VERIFY it at `idc_validation_contract.py freeze` (F64) — a re-implementation on
    either side is how the two would silently diverge."""
    body = {k: v for k, v in doc.items() if k != "result_digest"}
    blob = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def die(message: str, code: int = 2) -> None:
    print(f"idc-validation-risk-gate: {message}", file=sys.stderr)
    raise SystemExit(code)


def _hex(label: str, value: str, width: int = 64) -> str:
    text = str(value or "").strip()
    if len(text) != width or any(ch not in "0123456789abcdef" for ch in text):
        raise RiskGateError(f"{label} must be {width} lowercase hex characters (got {value!r})")
    return text


def _nonempty(label: str, value: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise RiskGateError(f"{label} must be non-empty")
    return text


def _string_list(label: str, values) -> list[str]:
    if not isinstance(values, list) or not values or any(not isinstance(it, str) or not it.strip() for it in values):
        raise RiskGateError(f"{label} must be a non-empty list of strings")
    return [it.strip() for it in values]


def _validate_risk_inputs(inputs) -> list[str]:
    ordered = []
    seen = set()
    for raw in inputs or []:
        if raw not in ALLOWED_RISK_INPUTS:
            raise RiskGateError(f"risk-input must be one of {ALLOWED_RISK_INPUTS}, got {raw!r}")
        if raw not in seen:
            ordered.append(raw)
            seen.add(raw)
    return ordered


def _normalize_touch_entry(entry: str) -> str:
    """One touch entry as the derivation table sees it: forward slashes, lowercased, no leading `./`.

    The `./` trim is deliberately a prefix strip and NOT `lstrip("./")` — the latter strips any
    leading run of `.` and `/` characters, which silently turns `.github/workflows/release.yml` into
    `github/...` and `.env` into `env`, i.e. it eats exactly the dotfile paths the security marker
    list exists to catch.
    """
    text = str(entry or "").strip().replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    return text.lower()


def derive_risk_inputs(touch: list, baseline: str = "unknown") -> list:
    """The risk inputs FIXED CODE reads out of the touch set it is given.

    Returns them in ALLOWED_RISK_INPUTS order so the result is stable and diffable. The division of
    labour is the point: the caller supplies the facts (`touch`, `baseline`), this function alone
    decides what risk they carry — so risk can be ADDED by declaration but never subtracted by
    omission. It does not read a frozen contract; see the module docstring's SCOPE OF THE GUARANTEE
    for exactly what that leaves unbound (F64).
    """
    entries = [_normalize_touch_entry(item) for item in (touch or [])]
    entries = [item for item in entries if item]
    derived = set()

    if len(entries) >= LARGE_TOUCH_SET_MIN:
        derived.add("large-touch-set")

    roots = {item.split("/", 1)[0] for item in entries if item.split("/", 1)[0]}
    if len(roots) >= CROSS_CUTTING_MIN_ROOTS:
        derived.add("cross-cutting-surface")

    for item in entries:
        if os.path.basename(item.rstrip("/")) in DEPENDENCY_MANIFESTS:
            derived.add("new-runtime-dependency")
            break

    for item in entries:
        if any(marker in item for marker in SECURITY_SENSITIVE_MARKERS):
            derived.add("security-sensitive-path")
            break

    if baseline == "expected-green":
        derived.add(BASELINE_RISK)

    return [name for name in ALLOWED_RISK_INPUTS if name in derived]


def _validate_candidate(prefix: str, candidate) -> dict:
    if not isinstance(candidate, dict):
        raise RiskGateError(f"{prefix} must be a mapping")
    keys = set(candidate)
    expected = set(CANDIDATE_KEYS)
    if keys != expected:
        raise RiskGateError(
            f"{prefix} must contain exactly {CANDIDATE_KEYS} (got {sorted(keys)})")
    clean = {}
    for key in CANDIDATE_KEYS:
        clean[key] = _nonempty(f"{prefix}.{key}", candidate.get(key))
    return clean


def _load_scenario(path: str):
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except OSError as exc:
        raise RiskGateError(f"could not read scenario {path}: {exc}") from exc
    except ValueError as exc:
        raise RiskGateError(f"scenario {path} is invalid JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise RiskGateError("scenario root must be a mapping")
    candidates = doc.get("candidates")
    skeptics = doc.get("skeptic_results")
    if not isinstance(candidates, list) or not candidates:
        raise RiskGateError("scenario.candidates must be a non-empty list")
    if not isinstance(skeptics, list) or len(skeptics) != len(candidates):
        raise RiskGateError("scenario.skeptic_results must be a list matching candidates length")
    clean_candidates = [_validate_candidate(f"candidate[{idx}]", cand) for idx, cand in enumerate(candidates)]
    clean_skeptics = []
    for idx, skeptic in enumerate(skeptics):
        if not isinstance(skeptic, dict):
            raise RiskGateError(f"skeptic_results[{idx}] must be a mapping")
        question = skeptic.get("question")
        if question != SKEPTIC_QUESTION:
            raise RiskGateError(
                f"skeptic_results[{idx}].question must be exactly {SKEPTIC_QUESTION!r}")
        defeated = skeptic.get("majority_defeated")
        if not isinstance(defeated, bool):
            raise RiskGateError(f"skeptic_results[{idx}].majority_defeated must be a boolean")
        repair = skeptic.get("repair")
        if repair is not None:
            repair = _validate_candidate(f"skeptic_results[{idx}].repair", repair)
        clean_skeptics.append({
            "question": question,
            "majority_defeated": defeated,
            "repair": repair,
        })
    return clean_candidates, clean_skeptics


def evaluate(*, validator_digest: str, frozen_gate_digest: str, attempt_ceiling: int,
             touch: list[str], off_limits: list[str], risk_inputs: list[str], scenario_path: str | None,
             baseline: str = "unknown"):
    validator_digest = _hex("validator_digest", validator_digest)
    frozen_gate_digest = _hex("frozen_gate_digest", frozen_gate_digest)
    if attempt_ceiling <= 0:
        raise RiskGateError("attempt_ceiling must be positive")
    if baseline not in BASELINE_CHOICES:
        raise RiskGateError(f"baseline must be one of {list(BASELINE_CHOICES)}, got {baseline!r}")
    touch = _string_list("touch", touch)
    off_limits = _string_list("off-limits", off_limits)
    declared = _validate_risk_inputs(risk_inputs)
    derived = derive_risk_inputs(touch, baseline)

    # The caller may ADD risk; it may not subtract it. Declared order is preserved (callers and the
    # governance lane assert on it), with anything fixed code found appended.
    effective = list(declared) + [name for name in derived if name not in declared]

    result = {
        "required": bool(effective),
        "risk_inputs": effective,
        "declared_risk_inputs": declared,
        "derived_risk_inputs": derived,
        "baseline": baseline,
        "derivation": {
            "derived_by_fixed_code": list(DERIVABLE_RISK_INPUTS),
            BASELINE_RISK: BASELINE_DERIVED_WHEN,
            "note": "`required` is the union of declared and derived risk; omitting --risk-input "
                    "cannot suppress a risk fixed code found in the frozen contract's touch set.",
        },
        "skeptic_question": SKEPTIC_QUESTION,
        "validator_digest": validator_digest,
        "frozen_gate_digest": frozen_gate_digest,
        "touch": touch,
        "off_limits": off_limits,
        "attempt_ceiling": int(attempt_ceiling),
        "selected": [],
        "discarded_indexes": [],
    }
    if not effective:
        result["result_digest"] = result_digest(result)
        return result
    if not scenario_path:
        source = "declared" if declared else "derived from the frozen contract"
        raise RiskGateError(
            f"high-risk discovery requires --scenario when any named risk input is present "
            f"({source}: {', '.join(effective)})")
    candidates, skeptics = _load_scenario(scenario_path)
    selected = []
    discarded = []
    for idx, (candidate, skeptic) in enumerate(zip(candidates, skeptics)):
        if skeptic["majority_defeated"]:
            discarded.append(idx)
            if skeptic["repair"] is not None:
                selected.append(skeptic["repair"])
            continue
        selected.append(candidate)
    result["selected"] = selected
    result["discarded_indexes"] = discarded
    # Stamped LAST, over the complete result, so the digest the freeze verifies covers the verdict
    # and the falsification outcome — not a prefix of them (F64).
    result["result_digest"] = result_digest(result)
    return result


def cmd_evaluate(args: argparse.Namespace) -> int:
    result = evaluate(
        validator_digest=args.validator_digest,
        frozen_gate_digest=args.frozen_gate_digest,
        attempt_ceiling=args.attempt_ceiling,
        touch=args.touch,
        off_limits=args.off_limits,
        risk_inputs=args.risk_input,
        scenario_path=args.scenario,
        baseline=args.baseline,
    )
    if args.out:
        parent = os.path.dirname(os.path.abspath(args.out)) or "."
        os.makedirs(parent, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2, sort_keys=True)
            fh.write("\n")
    else:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    ep = sub.add_parser("evaluate", help="evaluate the fixed risk predicate + bounded falsification results")
    ep.add_argument("--validator-digest", required=True)
    ep.add_argument("--frozen-gate-digest", required=True)
    ep.add_argument("--attempt-ceiling", type=int, required=True)
    ep.add_argument("--touch", action="append", required=True)
    ep.add_argument("--off-limits", action="append", required=True)
    ep.add_argument("--risk-input", action="append", default=[],
                    help="declare a named risk input; fixed code derives the rest from --touch and "
                         "--baseline, and a declaration can only ADD risk, never suppress it")
    ep.add_argument("--baseline", choices=BASELINE_CHOICES, default="unknown",
                    help="the frozen contract's baseline classification; `expected-green` derives "
                         "the expected-green-baseline risk input (omitted = that one dimension "
                         "stays declaration-only)")
    ep.add_argument("--scenario")
    ep.add_argument("--out")
    ep.set_defaults(func=cmd_evaluate)

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return args.func(args)
    except RiskGateError as exc:
        die(str(exc), code=2)


if __name__ == "__main__":
    raise SystemExit(main())
