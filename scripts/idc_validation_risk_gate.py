#!/usr/bin/env python3
"""Deterministic risk-gated divergent discovery / adversarial falsification for Plan.

The helper never authors tracker state or mutates the frozen gate. It only decides whether a ticket's
risk inputs require the bounded read-only divergent/falsification pass, validates the exact branch
schema, enforces the exact skeptic question, discards any gate defeated by a majority, and echoes the
fixed validator/frozen-gate/path/attempt inputs back unchanged so callers can prove discovery never
rewrote them.
"""
from __future__ import annotations

import argparse
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


class RiskGateError(Exception):
    pass


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
             touch: list[str], off_limits: list[str], risk_inputs: list[str], scenario_path: str | None):
    validator_digest = _hex("validator_digest", validator_digest)
    frozen_gate_digest = _hex("frozen_gate_digest", frozen_gate_digest)
    if attempt_ceiling <= 0:
        raise RiskGateError("attempt_ceiling must be positive")
    touch = _string_list("touch", touch)
    off_limits = _string_list("off-limits", off_limits)
    risk_inputs = _validate_risk_inputs(risk_inputs)
    result = {
        "required": bool(risk_inputs),
        "risk_inputs": risk_inputs,
        "skeptic_question": SKEPTIC_QUESTION,
        "validator_digest": validator_digest,
        "frozen_gate_digest": frozen_gate_digest,
        "touch": touch,
        "off_limits": off_limits,
        "attempt_ceiling": int(attempt_ceiling),
        "selected": [],
        "discarded_indexes": [],
    }
    if not risk_inputs:
        return result
    if not scenario_path:
        raise RiskGateError("high-risk discovery requires --scenario when any named risk input is present")
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
    ep.add_argument("--risk-input", action="append", default=[])
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
