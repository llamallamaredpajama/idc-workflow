#!/usr/bin/env python3
"""idc_brownfield_scan.py — `/idc:init`'s bounded, READ-ONLY requirements-doc + stack scan.

`/idc:init` Phase 1 runs this BEFORE Phase 3 scaffolds the tree. It answers two questions the
operator confirms: (1) does this repo already carry PRD / TRD / spec / consideration docs IDC should
scaffold-from rather than re-author, and (2) is it brownfield (an established stack) or greenfield
(a fresh project)? The answer sets the type-aware TRD-gating default — brownfield ON (protect an
established stack from silent re-architecture), greenfield OFF (let architecture flex).

HARD CONSTRAINT (locked decision #6 / gotcha #8): this scan CONFIRMS what exists — it NEVER invents.
It is strictly read-only: it opens nothing for writing, creates no files, and authors no architecture
doc. The whole point is that init reports the found docs and offers the operator scaffold-from-repo /
from-scratch / a mix, instead of fabricating an exhaustive arch doc at setup. The no-invent guarantee
is structural: there is no write path in this module.

The scan is BOUNDED — it inspects only well-known requirements-doc locations + a shallow walk of
`docs/`, plus top-level stack manifests. It does not recurse the whole tree or read file contents
(it reports paths, not summaries).

Usage: idc_brownfield_scan.py <repo-root>
       (exit 0 ok, 2 = bad usage / repo-root not a directory)

Output — stable, greppable lines (one finding per line; `<none>` when a category is empty):
    type: brownfield|greenfield
    gating-trd-default: on|off
    prd: <relpath>            (repeated per file; `prd: <none>` if none)
    trd: <relpath>            (the `spec`/architecture layer)
    considerations: <relpath>
    stack: <relpath>          (language/build manifest)
"""
import os
import sys

# Bounded scan locations. Requirements docs live in canonical IDC dirs or a handful of conventional
# top-level names; we glob those plus a shallow (depth-2) walk of docs/ — never the whole tree.
PRD_DIRS = ["docs/prd"]
TRD_DIRS = ["docs/specs", "docs/spec"]
CONSIDERATION_DIRS = ["docs/considerations"]
DOCS_ROOT = "docs"
DOCS_WALK_MAX_DEPTH = 2  # docs/ and one level under it

# Conventional single-file names (matched case-insensitively at repo root and under docs/).
PRD_NAMES = ("prd.md", "prd.markdown", "product-requirements.md", "requirements.md")
TRD_NAMES = ("trd.md", "spec.md", "architecture.md", "tech-spec.md",
             "technical-requirements.md", "master-architectural-spec.md")

# Top-level stack/build manifests — presence of any one marks an established (brownfield) repo.
STACK_MANIFESTS = (
    "package.json", "pnpm-lock.yaml", "yarn.lock",
    "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "uv.lock", "Pipfile",
    "Cargo.toml", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts",
    "Gemfile", "composer.json", "Package.swift", "mix.exs", "pubspec.yaml",
    "CMakeLists.txt", "Makefile",
)
# Source dirs that, like a manifest, signal an established codebase.
SOURCE_DIRS = ("src", "lib", "app", "pkg", "cmd", "internal", "source")


def _rel(repo_root, path):
    return os.path.relpath(path, repo_root)


def _md_files_in(repo_root, rel_dir):
    """Markdown files directly inside <repo_root>/<rel_dir> (non-recursive, sorted)."""
    base = os.path.join(repo_root, rel_dir)
    if not os.path.isdir(base):
        return []
    found = []
    for name in sorted(os.listdir(base)):
        full = os.path.join(base, name)
        if os.path.isfile(full) and name.lower().endswith((".md", ".markdown")):
            found.append(_rel(repo_root, full))
    return found


def _named_docs(repo_root, names):
    """Conventional doc names at repo root and one level under docs/ (case-insensitive)."""
    wanted = {n.lower() for n in names}
    hits = []
    # repo root
    for name in sorted(os.listdir(repo_root)) if os.path.isdir(repo_root) else []:
        full = os.path.join(repo_root, name)
        if os.path.isfile(full) and name.lower() in wanted:
            hits.append(_rel(repo_root, full))
    # shallow docs/ walk
    docs = os.path.join(repo_root, DOCS_ROOT)
    if os.path.isdir(docs):
        root_depth = docs.rstrip(os.sep).count(os.sep)
        for dirpath, dirnames, filenames in os.walk(docs):
            depth = dirpath.rstrip(os.sep).count(os.sep) - root_depth
            if depth >= DOCS_WALK_MAX_DEPTH:
                dirnames[:] = []  # stop descending
            for fn in sorted(filenames):
                if fn.lower() in wanted:
                    hits.append(_rel(repo_root, os.path.join(dirpath, fn)))
    return hits


def _collect(repo_root, dirs, names):
    seen, out = set(), []
    for d in dirs:
        for f in _md_files_in(repo_root, d):
            if f not in seen:
                seen.add(f); out.append(f)
    for f in _named_docs(repo_root, names):
        if f not in seen:
            seen.add(f); out.append(f)
    return sorted(out)


def _stack(repo_root):
    found = []
    for m in STACK_MANIFESTS:
        if os.path.isfile(os.path.join(repo_root, m)):
            found.append(m)
    return found


def _has_source_dir(repo_root):
    return any(os.path.isdir(os.path.join(repo_root, d)) for d in SOURCE_DIRS)


def _emit(label, items):
    if items:
        for it in items:
            print(f"{label}: {it}")
    else:
        print(f"{label}: <none>")


def main():
    argv = sys.argv[1:]
    if len(argv) != 1:
        sys.stderr.write("usage: idc_brownfield_scan.py <repo-root>\n")
        sys.exit(2)
    repo_root = os.path.abspath(argv[0])
    if not os.path.isdir(repo_root):
        sys.stderr.write(f"idc_brownfield_scan: not a directory: {repo_root}\n")
        sys.exit(2)

    prd = _collect(repo_root, PRD_DIRS, PRD_NAMES)
    trd = _collect(repo_root, TRD_DIRS, TRD_NAMES)
    considerations = _collect(repo_root, CONSIDERATION_DIRS, ())
    stack = _stack(repo_root)

    # Brownfield = an established codebase: a stack manifest, a source dir, or pre-existing
    # requirements docs. Greenfield = a fresh repo with none of those. Type-aware TRD default:
    # brownfield ON (protect the stack), greenfield OFF (let architecture flex).
    brownfield = bool(stack) or _has_source_dir(repo_root) or bool(prd) or bool(trd)
    repo_type = "brownfield" if brownfield else "greenfield"
    trd_default = "on" if brownfield else "off"

    print(f"type: {repo_type}")
    print(f"gating-trd-default: {trd_default}")
    _emit("prd", prd)
    _emit("trd", trd)
    _emit("considerations", considerations)
    _emit("stack", stack)


if __name__ == "__main__":
    main()
