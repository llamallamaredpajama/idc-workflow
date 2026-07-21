#!/usr/bin/env python3
"""Is the R28 census's walk actually looking? — the unit test for stderr_census.py.

    python3 tests/smoke/lib/test_stderr_census.py     # exit 0 = green

Run on its own, and run from R28 before the census does any real work. Two halves:

  PART ONE — the shapes. Every blind spot the census this replaces was measured to have,
  as a fixture with the answer written next to it. Each of these was RUN AGAINST THE OLD
  CENSUS FIRST and observed to come back CLEAN; a fixture the old code already handled
  proves nothing, and this repo has paid for that lesson once already (the `ghp_` sample
  in R28 that passed whichever order the code used).

  PART TWO — the mutations. The walk is broken on purpose, one guard at a time, and each
  mutant is required to FAIL. A guard nobody has watched fail is a guard nobody has
  tested; on today's tree the truncation rule finds ZERO real violations, so without this
  a walk with that rule entirely dead looks exactly like a working one.

Every mutation asserts its anchor matches EXACTLY ONCE before its result is believed. A
mutation that silently fails to apply reads precisely like a mutation that broke nothing,
and that has already manufactured one fake green in this suite.
"""
import os
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stderr_census as SC                                          # noqa: E402

MODULE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stderr_census.py")

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def classify(source, module="<fixture>"):
    """Run a fixture through the real walk and return its three verdicts as text."""
    reads, truncations = SC.analyze(textwrap.dedent(source).strip() + "\n", module)
    return (tuple(r.line for r in reads if not r.scrubbed),
            tuple(r.line for r in reads if r.scrubbed),
            tuple(t.line for t in truncations))


# ── PART ONE: the shapes ─────────────────────────────────────────────────────────────
# (label, why it is here, source, must-be-RAW, must-be-SCRUBBED, must-be-a-CUT)
#
# The first seven are the cases the old census misses, ranked by how likely the shape is
# to be written by someone doing their job properly. The rest are the controls: the
# things that must NOT fire, because a check that flags correct code gets switched off.
CASES = (
    ("(f) read taken off the call expression",
     "The strongest of them. The old pattern needed a word character before the dot, so "
     "`).stderr` was invisible — a whole SHAPE of read, not an odd spelling. This exact "
     "line already ships with `.stdout` at scripts/idc_worktree_stability.py:13; one "
     "character makes it a permanently unseen stderr read.",
     '''
     def run(cmd):
         detail = subprocess.run(cmd, capture_output=True, text=True).stderr
         return detail
     ''',
     ("detail = subprocess.run(cmd, capture_output=True, text=True).stderr",), (), ()),

    ("(c) named-constant cut inside the door",
     "The exact ordering bug the census was built for, respelled with a name instead of "
     "a number. scripts/idc_transition.py:1128 already writes `[:limit]`; move it one "
     "paren to the left and the old census sees nothing.",
     '''
     def tail(p):
         return CS.scrub(p.stderr.strip()[:MAX_TAIL])
     ''',
     (), ("return CS.scrub(p.stderr.strip()[:MAX_TAIL])",),
     ("return CS.scrub(p.stderr.strip()[:MAX_TAIL])",)),

    ("(i) a variable named `scrubbed` on the line",
     "The obvious name for the result of a scrub, and its mere presence satisfied the "
     "old test `\"scrub\" not in line`.",
     '''
     def detail(r):
         scrubbed = CS.scrub(r.stdout or "")
         return f"{scrubbed}\\n{r.stderr}"
     ''',
     ('return f"{scrubbed}\\n{r.stderr}"',), (), ()),

    ("(g) a raw read concatenated with a scrubbed one",
     "One scrub on the line licensed everything else on it.",
     '''
     def both(p):
         return CS.scrub(p.stdout or "") + " | " + p.stderr
     ''',
     ('return CS.scrub(p.stdout or "") + " | " + p.stderr',), (), ()),

    ("(b) a trailing comment containing the word scrub",
     "\"the caller already scrubs this\" is precisely the reasoning that produced "
     "F1/F20/F33/F35/F40 five times, and a comment is the natural place to write it.",
     '''
     def detail(p):
         return p.stderr  # the caller already ran it through the scrub door
     ''',
     ("return p.stderr  # the caller already ran it through the scrub door",), (), ()),

    ("(d) an unbalanced ) inside a string literal, before the cut",
     "The old paren counter had no idea what a string was, so it stopped at the `)` in "
     "the message and never reached the slice.",
     '''
     def detail(p):
         return CS.scrub("gh failed :) " + p.stderr.strip()[:200])
     ''',
     (), ('return CS.scrub("gh failed :) " + p.stderr.strip()[:200])',),
     ('return CS.scrub("gh failed :) " + p.stderr.strip()[:200])',)),

    ("(h) a real read on a line that also carries stderr=",
     "Shows what the old `\"stderr=\" in line` skip really was: a blanket substring "
     "test, not a keyword-argument test.",
     '''
     def detail(cmd):
         p = subprocess.run(cmd, stderr=subprocess.PIPE, text=True); return p.stderr
     ''',
     ("p = subprocess.run(cmd, stderr=subprocess.PIPE, text=True); return p.stderr",),
     (), ()),

    ("correct code written across several lines is CORRECT",
     "The false positive, and the one defect here that was never a leak: the old census "
     "silently required every scrub call to fit on one line, and REJECTED this — "
     "correctly ordered, correctly scrubbed code — with a bare-read failure.",
     '''
     def detail(p):
         return CS.scrub(
             p.stderr or ""
         ).strip()[:200]
     ''',
     (), ('p.stderr or ""',), ()),

    ("a read split across two lines is still a read",
     "Reachable, but nobody writes it — `p.stderr` is eight characters and no formatter "
     "in use here splits it. Covered because it is free to cover, not because it is a "
     "live risk. Note the key it produces: the joined line, so it can still be pasted "
     "into ALLOWED_RAW.",
     '''
     def detail(p):
         return (p
                 .stderr)
     ''',
     ("return (p .stderr)",), (), ()),

    ("both other spellings of the door count as the door",
     "`H.scrub` in scripts/hooks/, and the drain's bare `_scrub`. The proposal's own "
     "demo walk missed the second one.",
     '''
     def detail(r):
         a = H.scrub(r.stderr or "").strip()[:200]
         b = _scrub(r.stderr or "")
         return a, b
     ''',
     (), ('a = H.scrub(r.stderr or "").strip()[:200]', 'b = _scrub(r.stderr or "")'), ()),

    ("a name that merely CONTAINS scrub is not the door",
     "The old bug was `\"scrub\" in line`. Matching the callee's name by substring would "
     "be the same bug with better manners.",
     '''
     def detail(r):
         return _scrub_later(r.stderr)
     ''',
     ("return _scrub_later(r.stderr)",), (), ()),

    ("an index is not a truncation",
     "`d[\"k\"]` and `xs[0]` select; they do not shorten. Flagging them would teach the "
     "reader to ignore the check, which is how a check dies.",
     '''
     def detail(p, table):
         return CS.scrub(table["stderr"] + p.stderr[0])
     ''',
     (), ('return CS.scrub(table["stderr"] + p.stderr[0])',), ()),

    ("a cut inside a door handling no child stderr is not a finding",
     "Scoping the truncation rule to calls that actually hold a stderr read is required "
     "— otherwise every `CS.scrub(banner[:80])` in the repo becomes a violation.",
     '''
     def banner(p):
         return CS.scrub(p.stdout[:200] or "")
     ''',
     (), (), ()),

    ("our own stderr, a stderr= keyword and an attribute WRITE are not reads",
     "Three impostors, excluded by structure rather than by substring skips — which is "
     "what makes it safe to have dropped those skips.",
     '''
     def noise(cmd, fake):
         print("x", file=sys.stderr)
         subprocess.run(cmd, stderr=subprocess.PIPE)
         fake.stderr = "no child ran"
     ''',
     (), (), ()),
)

for label, _why, source, want_raw, want_scrubbed, want_cuts in CASES:
    got_raw, got_scrubbed, got_cuts = classify(source)
    ok = check(got_raw == want_raw and got_scrubbed == want_scrubbed and got_cuts == want_cuts,
               "%s\n      raw       expected %r\n                got      %r"
               "\n      scrubbed  expected %r\n                got      %r"
               "\n      cuts      expected %r\n                got      %r"
               % (label, want_raw, got_raw, want_scrubbed, got_scrubbed, want_cuts, got_cuts))
    print("  %s %s" % ("ok  " if ok else "FAIL", label))

# A module that will not parse is a census FAILURE, never a skip. The day a scripts/*.py
# uses syntax newer than the interpreter running the suite, a swallowed SyntaxError would
# delete that module from the census and report clean.
try:
    SC.analyze("def broken(:\n    pass\n", "scripts/idc_broken.py")
    check(False, "an unparseable module was accepted — a skipped module reports clean")
    print("  FAIL an unparseable module is a census failure")
except SC.ParseFailure as exc:
    check(exc.module == "scripts/idc_broken.py",
          "ParseFailure did not name the module it could not read")
    print("  ok   an unparseable module is a census failure, and names itself")

# …and not only when the parser calls it a SyntaxError. A stray null byte makes ast.parse
# raise ValueError, and "the census could not read this module" has to mean the same thing
# however the parser phrased it — otherwise there is a second, quieter way to be skipped.
try:
    SC.analyze("x = 1\0\n", "scripts/idc_nullbyte.py")
    check(False, "a module the parser refused for a non-syntax reason was accepted")
    print("  FAIL any parser refusal is a census failure, not only a SyntaxError")
except SC.ParseFailure as exc:
    check(exc.module == "scripts/idc_nullbyte.py", "ParseFailure did not name the module")
    print("  ok   any parser refusal is a census failure, not only a SyntaxError")

# The floor. 3.9 and not 3.8: on 3.8 a plain index arrives wrapped in an extra node, and
# the truncation rule would look at the wrong thing — quietly finding fewer violations.
try:
    SC.check_interpreter((3, 8, 20, "final", 0))
    check(False, "the floor accepted Python 3.8, where the truncation rule under-matches")
    print("  FAIL the floor refuses an interpreter the walk is not proven on")
except SC.InterpreterTooOld:
    SC.check_interpreter((3, 9, 0, "final", 0))          # must NOT raise
    SC.check_interpreter()                               # nor must the one we are on
    print("  ok   the floor refuses 3.8, admits 3.9, and admits this interpreter")

# The canary itself, on this interpreter.
try:
    SC.run_canary()
    print("  ok   the canary agrees with its hand-counted answer on Python %s"
          % sys.version.split()[0])
except SC.CanaryDrift as exc:
    check(False, "the canary drifted on this interpreter: %r" % (exc.drift,))
    print("  FAIL the canary agrees with its hand-counted answer")


# ── PART TWO: the mutations ──────────────────────────────────────────────────────────
def load_mutant(anchor, replacement):
    """Break the walk in one specific way and hand back the broken module.

    The anchor is asserted to match EXACTLY ONCE first. An edit that quietly matched
    nothing produces a mutant identical to the original, which then "passes" — and reads
    exactly like a guard that held.
    """
    with open(MODULE_PATH, encoding="utf-8") as handle:
        source = handle.read()
    hits = source.count(anchor)
    if hits != 1:
        raise AssertionError("anchor matched %d times, not once: %r" % (hits, anchor))
    namespace = {"__name__": "stderr_census_mutant", "__file__": MODULE_PATH}
    exec(compile(source.replace(anchor, replacement), MODULE_PATH + " [MUTATED]", "exec"),
         namespace)
    return namespace


def describe(drift):
    """Say what the canary noticed in one line: a count that moved, or the first site
    that appeared or vanished. The raw dict is accurate and unreadable."""
    said = []
    for name, (expected, got) in sorted(drift.items()):
        if not isinstance(expected, tuple):
            said.append("%s %d->%d" % (name, expected, got))
            continue
        gained = [line for line in got if line not in expected]
        lost = [line for line in expected if line not in got]
        if gained:
            said.append("%s gained %d, e.g. %r" % (name, len(gained), gained[0]))
        if lost:
            said.append("%s lost %d, e.g. %r" % (name, len(lost), lost[0]))
    return "; ".join(said)


def canary_trips(mutant):
    """The mutant must fail its own canary. Returns what the canary noticed."""
    try:
        mutant["run_canary"]()
    except mutant["CanaryDrift"] as exc:
        return describe(exc.drift)
    raise AssertionError("the canary passed — this guard has nothing watching it")


def floor_trips(mutant):
    """The mutant must stop refusing an interpreter the walk is not proven on."""
    try:
        mutant["check_interpreter"]((3, 8, 20, "final", 0))
    except mutant["InterpreterTooOld"]:
        raise AssertionError("the floor still refused 3.8 — the mutation changed nothing")
    return "Python 3.8 was accepted, so `x[:200]`'s shape is no longer the one this walks"


def parse_failure_trips(mutant):
    """The mutant must stop treating an unreadable module as a failure."""
    try:
        mutant["analyze"]("def broken(:\n    pass\n", "scripts/idc_broken.py")
    except mutant["ParseFailure"]:
        raise AssertionError("the parse failure still raised — the mutation changed nothing")
    return "an unparseable module was skipped, so the census clears what it cannot read"


# (class, what is broken, anchor, replacement, what must then fail)
MUTATIONS = (
    ("deletion", "drop the read-vs-write test on the attribute",
     "            and isinstance(node.ctx, ast.Load)\n", "",
     canary_trips),

    ("deletion", "drop the scoping of the truncation rule to doors holding stderr",
     "        if not reads_here:\n            continue\n", "",
     canary_trips),

    ("deletion", "drop the interpreter floor's refusal",
     '        raise InterpreterTooOld(MIN_PYTHON, "%d.%d.%d" % tuple(version[:3]))',
     "        pass",
     floor_trips),

    ("deletion", "drop the parse-failure refusal and skip the module instead",
     '        raise ParseFailure(module, "%s: %s" % (type(exc).__name__, exc))',
     "        return [], []",
     parse_failure_trips),

    ("value", "forget that the drain calls the door `_scrub`",
     'SCRUB_NAMES = frozenset(("scrub", "_scrub"))', 'SCRUB_NAMES = frozenset(("scrub",))',
     canary_trips),

    ("value", "lower the floor to 3.8",
     "MIN_PYTHON = (3, 9)", "MIN_PYTHON = (3, 8)",
     floor_trips),

    ("value", "take the exemption key from the line after the read",
     "        return lines[first - 1].strip()", "        return lines[first].strip()",
     canary_trips),

    ("substitution", "match the door's name by substring instead of exactly",
     "        if not isinstance(node, ast.Call) or _callee_name(node) not in SCRUB_NAMES:",
     '        if not isinstance(node, ast.Call) or "scrub" not in _callee_name(node):',
     canary_trips),

    ("substitution", "count every subscript as a cut, not only a slice",
     "            if isinstance(inner, ast.Subscript) and isinstance(inner.slice, ast.Slice):",
     "            if isinstance(inner, ast.Subscript):",
     canary_trips),

    ("substitution", "look only at each argument's outermost node, not inside it",
     "    return [node for argument in arguments for node in ast.walk(argument)]",
     "    return list(arguments)",
     canary_trips),
)

print("  -- mutations (each anchor asserted to match exactly once) --")
for kind, what, anchor, replacement, must_fail in MUTATIONS:
    try:
        observed = must_fail(load_mutant(anchor, replacement))
        print("  ok   RED  [%s] %s\n          => %s" % (kind, what, observed))
    except AssertionError as exc:
        check(False, "[%s] %s stayed GREEN: %s" % (kind, what, exc))
        print("  FAIL GREEN [%s] %s — %s" % (kind, what, exc))

if failures:
    print("\ntest_stderr_census: %d FAILED" % len(failures))
    for message in failures:
        print("  - %s" % message)
    sys.exit(1)
print("test_stderr_census: OK (Python %s)" % sys.version.split()[0])
