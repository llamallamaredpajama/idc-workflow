#!/usr/bin/env python3
"""idc_consideration_check.py — validate an IDC consideration file.

A consideration is /idc:think's output: a function-first description of what the code
should do for the user and how it behaves (`WORKFLOW.md §4.1`, the considerations schema
skill). In v3 Think crystallizes the consideration into a **PRD + TRD draft** and fires the one
gate at the end of Think (the Think PR), so the consideration must signal **both** the
user-facing *what* (PRD) and the technical *how* (TRD) it drives. This is the mechanical check
that keeps a consideration admission-ready — guardrails, not train tracks, so it checks only the
load-bearing essentials, not prose style.

Required:
  1. an H1 title;
  2. a function-first section — a heading mentioning the user or the function (function
     FIRST, not an implementation task list);
  3. a `PRD impact:` statement (does user-facing function change? — it drives the PRD draft);
  4. a `TRD impact:` statement (does the technical approach change? — it drives the TRD draft);
  5. an `Open questions` section (the handoff to Plan).

Usage: idc_consideration_check.py <consideration.md>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import re
import sys


def check(text):
    lines = text.splitlines()
    problems = []
    if not any(re.match(r"^#\s+\S", ln) for ln in lines):
        problems.append("missing an H1 title (`# <topic> — Consideration`)")
    if not any(re.match(r"^#{2,}\s", ln) and re.search(r"user|function", ln, re.I) for ln in lines):
        problems.append("missing a function-first section (a heading describing what it does "
                        "for the user / its function — function first, not tasks)")
    if not re.search(r"PRD impact", text, re.I):
        problems.append("missing a `PRD impact:` statement (does user-facing function change? "
                        "— it drives the PRD draft)")
    if not re.search(r"TRD impact", text, re.I):
        problems.append("missing a `TRD impact:` statement (does the technical approach change? "
                        "— it drives the TRD draft)")
    if not any(re.match(r"^#{2,}\s", ln) and re.search(r"open question", ln, re.I) for ln in lines):
        problems.append("missing an `Open questions` section (handoff to Plan)")
    return problems


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_consideration_check.py <consideration.md>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        sys.stderr.write(f"idc-consideration-check: cannot read {sys.argv[1]}: {e}\n")
        sys.exit(2)
    problems = check(text)
    if problems:
        print("consideration check: FAIL")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print("consideration check: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
