#!/usr/bin/env python3
"""
Cross-check markdown files for references to workflow machine states, ensuring they
exist in the canonical `workflow-machine.yaml`.
"""
import argparse
import os
import re
import sys

class YamlParseError(Exception):
    pass

# --- Start: Copied from scripts/idc_transition.py ---
def _mini_yaml(text):
    """A tiny stdlib parser for the CONSTRAINED YAML subset workflow-machine.yaml uses (this repo
    ships no PyYAML). Handles: `key: scalar`, nested `key:` block maps by 2-space indent, inline flow
    lists `[a, b, c]` and inline flow maps `{k: v, k: v}` of flat scalars, `#` comments, blanks.
    Deliberately NOT a general YAML parser — it round-trips exactly the machine table's shape."""
    def coerce(s):
        s = s.strip()
        if len(s) >= 2 and s[0] in "\"'" and s[-1] == s[0]:
            return s[1:-1]
        if s in ("true", "True", "TRUE"):
            return True
        if s in ("false", "False", "FALSE"):
            return False
        if s in ("null", "Null", "NULL", "~"):
            return None
        body = s[1:] if s[:1] == "-" else s
        if body.isdigit() and body != "":
            return int(s)
        return s

    def parse_scalar(s):
        s = s.strip()
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1].strip()
            return [parse_scalar(p) for p in inner.split(",")] if inner else []
        if s.startswith("{") and s.endswith("}"):
            inner = s[1:-1].strip()
            out = {}
            if inner:
                for pair in inner.split(","):
                    k, _, v = pair.partition(":")
                    out[k.strip()] = parse_scalar(v)
            return out
        return coerce(s)

    lines = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            raise YamlParseError(
                f"machine table: block-style list ('{stripped}') is unsupported by the stdlib "
                "fallback parser — use an inline flow list [a, b, c] (or install PyYAML)")
        if ":" not in stripped:
            raise YamlParseError(
                f"machine table: unsupported line {stripped!r} — the stdlib fallback parser expects "
                "`key: value` (or install PyYAML)")
        indent = len(raw) - len(raw.lstrip(" "))
        key, _, val = stripped.partition(":")
        lines.append((indent, key.strip(), val.strip()))

    def build(idx, indent):
        out = {}
        i = idx
        while i < len(lines):
            ind, key, val = lines[i]
            if ind < indent:
                break
            if ind > indent:
                i += 1
                continue
            if val == "":
                child, i = build(i + 1, indent + 2)
                out[key] = child
            else:
                out[key] = parse_scalar(val)
                i += 1
        return out, i

    doc, _ = build(0, 0)
    return doc

def load_machine(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml
        doc = yaml.safe_load(text)
    except ImportError:
        doc = _mini_yaml(text)
    if not isinstance(doc, dict):
        raise YamlParseError(f"machine table {path} is malformed")
    return doc
# --- End: Copied from scripts/idc_transition.py ---


def find_references(file_content):
    """Find all potential workflow references in a file based on specific patterns."""
    references = set()
    
    # Pattern for `Stage: Value` and `Status: Value` or `Status: Multi Word Value`.
    # It requires the value to be capitalized. This is a strong signal.
    key_value_pattern = re.compile(r"\b(Stage|Status):\s*([A-Z][a-zA-Z]+(?:\s[A-Z][a-zA-Z]+)*)\b")
    for match in key_value_pattern.finditer(file_content):
        references.add(match.group(2))

    # The check for backticked op names has been removed as it was too noisy,
    # catching many false positives like script names and command flags.
    # The primary risk is stale Stage/Status names, which are just strings. Op names
    # are more tightly coupled to the transition engine's argument parser.

    return references


def main():
    parser = argparse.ArgumentParser(description="Check for valid workflow references in markdown files.")
    parser.add_argument("files", nargs="+", help="Files to check.")
    parser.add_argument("--machine-yaml", required=True, help="Path to workflow-machine.yaml")
    args = parser.parse_args()

    try:
        machine = load_machine(args.machine_yaml)
    except (FileNotFoundError, YamlParseError) as e:
        print(f"Error loading machine YAML: {e}", file=sys.stderr)
        return 1

    valid_stages = set(machine.get("stages", []))
    valid_statuses = set(machine.get("statuses", []))
    
    all_valid_terms = valid_stages.union(valid_statuses)

    errors = []
    for fpath in args.files:
        try:
            # The test file is created in a temp dir, but lint-references.sh also scans
            # the real content files, so we check existence.
            if not os.path.exists(fpath):
                continue
            with open(fpath, "r", encoding="utf-8") as f:
                content = f.read()
            
            references = find_references(content)
            
            for ref in references:
                if ref not in all_valid_terms:
                    # To find the line number for a better error message
                    for i, line in enumerate(content.splitlines()):
                        if ref in line:
                            errors.append(f"{fpath}:{i+1}: Invalid workflow reference: '{ref}'")
                            break # report first occurrence

        except Exception as e:
            errors.append(f"Could not process {fpath}: {e}")
    
    if errors:
        # Print unique, sorted errors for deterministic output
        for error in sorted(list(set(errors))):
            print(error, file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
