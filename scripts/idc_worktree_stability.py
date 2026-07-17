#!/usr/bin/env python3
"""Read-only post-process worktree stability check."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time


def _git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True).stdout


def fingerprint(repo):
    digest = hashlib.sha256()
    head = _git(repo, "rev-parse", "HEAD").strip().decode("ascii")
    index = _git(repo, "ls-files", "--stage", "-z")
    digest.update(_git(repo, "diff", "--binary", "HEAD", "--"))
    untracked = _git(repo, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    for raw in sorted(p for p in untracked if p):
        digest.update(raw + b"\0")
        path = os.path.join(repo, os.fsdecode(raw))
        if os.path.islink(path):
            digest.update(os.fsencode(os.readlink(path)))
        elif os.path.isfile(path):
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
    return {"head": head, "index": hashlib.sha256(index).hexdigest(), "worktree": digest.hexdigest()}


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--wait-timeout", type=float, default=60.0)
    args = parser.parse_args(argv)
    if args.samples < 3:
        parser.error("--samples must be at least 3")
    repo = os.path.abspath(args.repo)
    baseline = fingerprint(repo)
    if args.pid:
        deadline = time.monotonic() + args.wait_timeout
        while _alive(args.pid):
            if time.monotonic() >= deadline:
                print("worktree-stability: process did not exit before timeout", file=sys.stderr)
                return 2
            time.sleep(min(args.interval, 0.25))
    observed = []
    for n in range(args.samples):
        observed.append(fingerprint(repo))
        if n + 1 < args.samples:
            time.sleep(args.interval)
    if any(sample != baseline for sample in observed) or len({json.dumps(x, sort_keys=True) for x in observed}) != 1:
        print("worktree-stability: FAIL — HEAD, index, or worktree changed", file=sys.stderr)
        return 1
    print(json.dumps({"stable": True, "samples": args.samples, "fingerprint": baseline}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
