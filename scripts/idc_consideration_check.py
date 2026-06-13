#!/usr/bin/env python3
"""idc_consideration_check.py — validate an IDC v2 consideration file.

A consideration is /idc:think's output: a function-first description of what the code
should do for the user and how it behaves (`WORKFLOW.md §4.1`, the considerations schema
skill). This is the mechanical gate that keeps a consideration Plan-ready — guardrails, not
train tracks, so it checks only the load-bearing essentials, not prose style.

Required:
  1. an H1 title;
  2. a function-first section — a heading mentioning the user or the function (function
     FIRST, not an implementation task list);
  3. a `PRD impact:` statement (does user-facing function change? — Plan's gate keys on it,
     though Think never pre-clears the PRD);
  4. an `Open questions` section (the handoff to Plan).

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
        problems.append("missing a `PRD impact:` statement (does user-facing function change?)")
    if not any(re.match(r"^#{2,}\s", ln) and re.search(r"open question", ln, re.I) for ln in lines):
        problems.append("missing an `Open questions` section (handoff to Plan)")
    return problems


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_consideration_check.py <consideration.md>\n")
        sys.exit(2)
    try:
        text = open(sys.argv[1], encoding="utf-8").read()
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
