"""Broken-pipe hygiene for IDC's operator-facing CLIs — the ONE place the guard is defined.

THE FAILURE THIS CLOSES. `idc_command_contract.py status --repo <r> --json | head` printed a Python
traceback and exited non-zero. Nothing was wrong with the command: `head` takes what it wants and
closes the pipe, and the writer's next write to that closed pipe raises `BrokenPipeError`. Python
sets SIGPIPE to SIG_IGN at interpreter start, so a broken pipe surfaces as an exception rather than
the silent death every other unix tool dies of — an unguarded CLI therefore turns the single most
ordinary thing an operator does (piping a long report to `head` or `less`) into a crash.

WHY IT LOOKED LIKE IT WASN'T THERE. Whether it bites depends on how much of the payload fits in the
kernel's pipe buffer before the reader leaves: 16 KB on macOS (growable to 64 KB), 4 KB on Linux. A
report that fits never touches the closed pipe and never raises. That is why this was invisible on a
developer's mac and fatal on a Linux runner, and why "cannot reproduce locally" is not evidence of
absence — it is evidence of a bigger buffer.

THE GUARD IS THREE PARTS, AND ALL THREE ARE LOAD-BEARING. A guard that catches the exception and
stops there is not fixed, only quieter — the interpreter still flushes stdout on the way out, that
flush hits the same closed pipe, and Python prints `Exception ignored in: <_io.TextIOWrapper name=
'<stdout>' ...>` to stderr and exits 120. So `run_guarded` (1) flushes stdout INSIDE the try, so a
payload still sitting in Python's own buffer fails where it can be caught rather than at shutdown;
(2) catches `BrokenPipeError`; and (3) points fd 1 at /dev/null, so the shutdown flush the
interpreter runs after this function returns has somewhere harmless to go.

WHY NOT `signal(SIGPIPE, SIG_DFL)`. Restoring the default handler is the one-line version, and it is
wrong here: it kills the process at an arbitrary write, anywhere, including mid-way through a ledger
or board mutation. IDC's CLIs are not all pure readers. Catching the exception at the outermost
boundary confines the behavior to the report-printing path that actually wants it, and leaves every
write door to finish or fail on its own terms.

EXIT CODE. `BROKEN_PIPE_EXIT = 141` — the 128+SIGPIPE code a shell reports for any ordinary tool the
same `| head` kills, so IDC's CLIs read like the rest of the system. It is deliberately NOT 0, 1, 2,
or 4: those are load-bearing IDC verdicts (persisted / could-not-persist / rejected / stale runtime),
and a truncated report must never be mistaken for one of them by a caller reading the exit code.

WHICH CLIs GET THE GUARD (the selection criterion — write it down, because "we thought about it and
decided no" and "nobody thought about it" look identical in a diff). A shipped `scripts/*.py` needs
`run_guarded` in its `__main__` block if EITHER is true:

  * it has a `--json` mode (JSON is what gets piped to `jq`, and `jq` closes the pipe early on
    `first(...)`, `head -1`, or any error); or
  * any of its output is UNBOUNDED IN LENGTH — one line per issue, per finding, per board item, per
    cure. Bounded output (a fixed handful of verdict lines) is the ONLY safe exemption, and it is safe
    only because it fits in the smallest pipe buffer (4 KB on Linux), not because it is short-looking.

That second clause is why the criterion is written in terms of the payload rather than "is this
operator-facing": whether an unguarded CLI crashes depends on how much fits in the kernel's pipe
buffer before the reader leaves, so a report that is usually short but occasionally long is exactly
the case that passes review and then fails in CI. When in doubt, add the guard — it costs two lines
and changes nothing about a CLI whose reader stays.

Deliberately NOT guarded: modules that are only ever imported (they must not install process-wide
stdout behavior — see `run_guarded`'s own note), and hooks under `scripts/hooks/`, which talk to
Claude Code over a JSON protocol on a pipe that is never a human's `| head`.
"""
from __future__ import annotations

import os
import sys

# 128 + SIGPIPE(13) — see the module docstring on why this must not collide with an IDC verdict code.
BROKEN_PIPE_EXIT = 141


def silence_stdout() -> None:
    """Point fd 1 at /dev/null so the interpreter's shutdown flush cannot re-raise on a dead pipe.

    Best-effort by design: this runs while the process is already giving up on stdout, so a failure
    to open or dup /dev/null must not itself raise — the worst case is the noisy shutdown message we
    were trying to suppress, which is strictly better than a second exception on the way out."""
    try:
        devnull = os.open(os.devnull, os.O_WRONLY)
    except OSError:
        return
    try:
        os.dup2(devnull, sys.stdout.fileno())
    except (OSError, ValueError):
        pass
    finally:
        try:
            os.close(devnull)
        except OSError:
            pass


def run_guarded(main_fn):
    """Run a zero-argument CLI `main` with the broken-pipe guard wrapped around it.

    Use it as `raise SystemExit(idc_stdio.run_guarded(main))`. Returns main's own exit code normally,
    or `BROKEN_PIPE_EXIT` when the reader on the other end of stdout went away. `main` is called with
    NO arguments because that is how every `__main__` block in this repo already calls it (they read
    `sys.argv` themselves); a main that takes an optional `argv` works unchanged.

    Call it ONLY from a `__main__` block. Importing a module must not install process-wide stdout
    behavior — `idc_gh_board` alone is imported as a library by fourteen other scripts, and the smoke
    suites import several of these CLIs to exercise their internals directly.

    THE `SystemExit` ARM IS NOT OPTIONAL. Most of these CLIs never return a code — they end in
    `sys.exit(code)` deep inside `main`. That raises `SystemExit`, which is NOT a subclass of
    `Exception` and would sail straight past a naive guard, skipping the flush below and leaving the
    interpreter to discover the dead pipe at shutdown, where nothing can catch it. Catching it here,
    then flushing, then re-raising the same code through the caller's `raise SystemExit(...)`
    preserves the exit semantics exactly — including `SystemExit(None)` (exit 0) and the
    `sys.exit("message")` form, whose string still reaches stderr and still exits 1.

    The explicit flush is not decoration either: without it a payload that fits in Python's own
    buffer never fails inside this try, and the failure resurfaces at interpreter shutdown. See the
    module docstring."""
    try:
        try:
            code = main_fn()
        except SystemExit as exc:
            code = exc.code
        sys.stdout.flush()
        return code
    except BrokenPipeError:
        silence_stdout()
        return BROKEN_PIPE_EXIT
