#!/usr/bin/env python3
"""Is the R28 census's walk actually looking? — the unit test for stderr_census.py.

    python3 tests/smoke/lib/test_stderr_census.py     # exit 0 = green

Run on its own, and run from R28 before the census does any real work. Four parts, and
they climb: each one watches the layer above the one before it.

  PART ONE — the shapes. Every blind spot the census this replaces was measured to have,
  as a fixture with the answer written next to it. All fifteen were RUN AGAINST THE OLD
  CENSUS and their answers recorded before they were written down; a fixture the old code
  already handled proves nothing, and this repo has paid for that lesson once already (the
  `ghp_` sample in R28 that passed whichever order the code used). Thirteen came back
  CLEAN from the old census — that is what makes them blind spots. It REJECTED the other
  two, and both rejections were false positives this walk fixes: the multi-line scrub
  call, and an attribute WRITE it could not tell from a read. (This paragraph used to
  claim all of them came back clean. Two did not, and the second false positive had gone
  uncredited since round 5.)

  PART TWO — the judgement. Small fixture trees with a known-bad module in them, pushed
  through `census()` and `judge()` — the code that decides, as opposed to the code that
  looks. This part exists because it was missing: an independent verifier broke the
  judgement layer six ways, planted a real credential-leaking read in scripts/ each time,
  and watched both gates report success. Everything below the judgement was excellently
  covered; the judgement itself had no assertions behind it at all.

  PART THREE — the whole case, end to end. R28's own census program, lifted verbatim out
  of phase11-honesty-repro.sh and run against a tree that IS the real one plus a planted
  violation. Not a copy of R28's logic — R28's logic. This is the only part that can
  prove R28's verdict arms, its two floors, its registry and its prose actually fire,
  because on the real tree every one of them is silent by design.

  That sentence used to name the count floors among the things this part proved, and it
  was false: no fixture here tripped them. A reviewer disabled the floors, watched all 64
  assertions stay green, then narrowed the file set and watched a real planted credential
  leak clear R28 with exit 0. That was the FOURTH time in this work that a guard turned
  out to have been described as covered while nothing watched it — after the ordering
  rule, the judgement layer and this battery's own contents — and all four were found by
  somebody who had not built the thing. The floors have a fixture now; the sentence above
  is now true; and the useful lesson is the one about who found it.

  PART FOUR — the mutations. Each guard is broken on purpose and the fixture that watches
  it is required to STOP REFUSING. A guard nobody has watched fail is a guard nobody has
  tested; on today's tree the truncation rule finds ZERO real violations, so without this
  a walk with that rule entirely dead looks exactly like a working one — and the same
  sentence is true, one storey up, of every arm in R28.

Every mutation asserts its anchor matches EXACTLY ONCE before its result is believed. A
mutation that silently fails to apply reads precisely like a mutation that broke nothing,
and that has already manufactured one fake green in this suite.
"""
import atexit
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
SMOKE_DIR = os.path.dirname(LIB_DIR)
PLUGIN = os.path.dirname(os.path.dirname(SMOKE_DIR))
SUITE_PATH = os.path.join(SMOKE_DIR, "phase11-honesty-repro.sh")

sys.path.insert(0, LIB_DIR)
import stderr_census as SC                                          # noqa: E402

MODULE_PATH = os.path.join(LIB_DIR, "stderr_census.py")

# One scratch directory for every fixture tree this file builds, removed on the way out.
SCRATCH = tempfile.mkdtemp(prefix="stderr-census-fixtures-")
atexit.register(shutil.rmtree, SCRATCH, True)
_serial = [0]


def scratch_dir(what):
    _serial[0] += 1
    path = os.path.join(SCRATCH, "%s%d" % (what, _serial[0]))
    os.makedirs(path)
    return path

failures = []
PASSED = [0]


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def say(ok, text):
    """Print one verdict line, and COUNT it when it passed.

    The count is the last line this file prints, and R28 puts a FLOOR under it. That is
    not ceremony either: R28 checks that this battery still RUNS, and running is not the
    same as containing anything. Empty the fixture tables below and this file exits 0
    with a shorter transcript — which was measured, not imagined, and is the third storey
    of one failure. See R28's step (0b) for the whole of it.
    """
    if ok:
        PASSED[0] += 1
    print("  %s %s" % ("ok  " if ok else "FAIL", text))


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

    ("the door counts when it is handed the read by KEYWORD, not only by position",
     "`scrub(text=...)` is the same call through the same door, and treating it as a bare "
     "read would flag correct code — which is how a check gets switched off. The keyword "
     "arm can be deleted from the walk with nothing else here going red, so this fixture "
     "is the only thing watching it. It fails CLOSED (the read would be reported bare, "
     "loudly) so it was a coverage gap rather than a hole, but a stated rule with no "
     "example behind it is how the rest of this file's findings started.",
     '''
     def detail(p):
         return CS.scrub(text=p.stderr or "").strip()[:200]
     ''',
     (), ('return CS.scrub(text=p.stderr or "").strip()[:200]',), ()),

    ("a name that merely CONTAINS scrub is not the door",
     "The old bug was `\"scrub\" in line`. Matching the callee's name by substring would "
     "be the same bug with better manners.",
     '''
     def detail(r):
         return _scrub_later(r.stderr)
     ''',
     ("return _scrub_later(r.stderr)",), (), ()),

    ("an index is not a truncation",
     "`table[\"stderr\"]` selects a value out of a mapping; flagging it would teach the "
     "reader to ignore the check, which is how a check dies. The rationale has to be "
     "stated more carefully than it once was, because this fixture's own second half — "
     "`p.stderr[0]` — DOES shorten, to one character. What the rule says is narrower "
     "than \"an index never shortens\": it recognises a cut only when the cut is spelled "
     "as a SLICE. Nobody writes `p.stderr[0]` and one character carries no credential, "
     "so leaving it unflagged is right — but the spellings that ARE cuts and are not "
     "slices leak, and they are named in R28's boundary paragraph, not hidden here.",
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
     "what makes it safe to have dropped those skips. The WRITE is also the old census's "
     "SECOND false positive, and it went uncredited for two rounds: `fake.stderr = \"no "
     "child ran\"` was reported by the old regex as a bare read of a child's stderr, "
     "because a pattern cannot tell a write from a read. The parse tree can, and does.",
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
    say(ok, label)

# A module that will not parse is a census FAILURE, never a skip. The day a scripts/*.py
# uses syntax newer than the interpreter running the suite, a swallowed SyntaxError would
# delete that module from the census and report clean.
try:
    SC.analyze("def broken(:\n    pass\n", "scripts/idc_broken.py")
    check(False, "an unparseable module was accepted — a skipped module reports clean")
    say(False, "an unparseable module is a census failure")
except SC.ParseFailure as exc:
    # `say` takes the CHECK's answer, not a literal True. Three of these lines used to
    # announce a pass unconditionally, so the check behind them could fail without moving
    # the tally R28 floors — a small hole of exactly the kind this file is about.
    say(check(exc.module == "scripts/idc_broken.py",
              "ParseFailure did not name the module it could not read"),
        "an unparseable module is a census failure, and names itself")

# …and not only when the parser calls it a SyntaxError. A stray null byte makes ast.parse
# raise ValueError, and "the census could not read this module" has to mean the same thing
# however the parser phrased it — otherwise there is a second, quieter way to be skipped.
try:
    SC.analyze("x = 1\0\n", "scripts/idc_nullbyte.py")
    check(False, "a module the parser refused for a non-syntax reason was accepted")
    say(False, "any parser refusal is a census failure, not only a SyntaxError")
except SC.ParseFailure as exc:
    say(check(exc.module == "scripts/idc_nullbyte.py",
              "ParseFailure did not name the module"),
        "any parser refusal is a census failure, not only a SyntaxError")

# The floor. 3.9 and not 3.8 — but NOT for the reason this comment used to give. It said
# 3.8 wraps a plain index in an extra node so the truncation rule under-matches; that was
# measured on a real 3.8.20 and is false, the cut rule answers identically there. What 3.8
# really gets wrong is the exemption KEY: a read inside a multi-line f-string is reported
# at the f-string's opening line, so 7 of the 25 keys on today's tree come out wrong with
# every count perfect and the canary green. See MIN_PYTHON in stderr_census.py.
try:
    SC.check_interpreter((3, 8, 20, "final", 0))
    check(False, "the floor accepted Python 3.8, where the truncation rule under-matches")
    say(False, "the floor refuses an interpreter the walk is not proven on")
except SC.InterpreterTooOld:
    SC.check_interpreter((3, 9, 0, "final", 0))          # must NOT raise
    SC.check_interpreter()                               # nor must the one we are on
    say(True, "the floor refuses 3.8, admits 3.9, and admits this interpreter")

# The canary itself, on this interpreter.
try:
    SC.run_canary()
    say(True, "the canary agrees with its hand-counted answer on Python %s"
        % sys.version.split()[0])
except SC.CanaryDrift as exc:
    check(False, "the canary drifted on this interpreter: %r" % (exc.drift,))
    say(False, "the canary agrees with its hand-counted answer")


# ── PART TWO: the judgement, on trees that have something wrong with them ────────────
# Everything above tests `analyze` — the code that LOOKS. Nothing above ever calls
# `census()` or `judge()`, the code that DECIDES, and that is where the guard was found
# to have no evidence behind it. `census()` could throw away every truncation `analyze`
# handed it, or mark every read scrubbed, and the canary above would still pass green,
# because the canary calls `analyze` directly and cannot see one function further out.
#
# So: build a small scripts/ tree with a known-bad module in it and push it through the
# real `census()` and the real `judge()`. Each fixture also names the SITES it expects,
# not just the count — a verdict that fires on the wrong line is a verdict a person
# cannot act on, and it is also how a walk that has started matching something else
# would still look right.
SCRUBBED_READ = '''
def detail(p):
    return CS.scrub(p.stderr or "").strip()[:200]
'''
HOOK_SCRUBBED_READ = '''
def detail(r):
    return H.scrub(r.stderr or "").strip()[:200]
'''
BARE_READ = '''
def detail(proc):
    return f"gh gate check failed: {proc.stderr.strip()[:200]}"
'''
CUT_INSIDE_THE_DOOR = '''
def detail(proc):
    return f"gh gate check failed: {CS.scrub(proc.stderr.strip()[:200])}"
'''
CLASSIFIED_READ = '''
def is_rate_limited(p):
    if _is_rate_limit_stderr(p.stderr):
        return True
    return False
'''
RATE_LIMIT_KEY = ("scripts/idc_gh_board.py", "if _is_rate_limit_stderr(p.stderr):")
REASON = "rate-limit detection: the message built two lines down is scrubbed"


def tree(modules):
    """Write a miniature shipped tree — scripts/ and scripts/hooks/ — and return its root.

    Values are source text, or raw bytes when the point of the fixture is that the file
    cannot be decoded at all.
    """
    root = scratch_dir("tree")
    os.makedirs(os.path.join(root, "scripts", "hooks"))
    for rel, source in modules.items():
        if not isinstance(source, bytes):
            source = (textwrap.dedent(source).strip() + "\n").encode("utf-8")
        with open(os.path.join(root, *rel.split("/")), "wb") as handle:
            handle.write(source)
    return root


def verdict_of(modules, allowed_raw):
    """The real census and the real judgement, over a real (tiny) tree on disk."""
    scan = SC.census(tree(modules))
    found = SC.judge(scan, allowed_raw)
    return {
        "bare": tuple(read.where() for read in found.bare),
        "ambiguous": tuple(read.where()
                           for _key, reads in found.ambiguous for read in reads),
        "stale": tuple("%s: %s" % key for key in found.stale),
        "truncations": tuple(cut.where() for cut in found.truncations),
    }


# (label, why it is here, the tree, the registry, what must be found — arms not named
#  here must come back EMPTY)
JUDGEMENTS = (
    ("a tree with nothing wrong with it is CLEAN",
     "The control. Without it every fixture below could be firing for a reason that has "
     "nothing to do with what it claims to test — and a judgement that refuses "
     "everything is as useless as one that refuses nothing.",
     {"scripts/idc_a.py": SCRUBBED_READ, "scripts/hooks/idc_h.py": HOOK_SCRUBBED_READ},
     {}, {}),

    ("a bare read is a finding, and the finding names its site",
     "The arm that carries the whole case. Deleting it from R28 and planting a real "
     "unscrubbed `proc.stderr` in scripts/ was measured to leave BOTH gates green.",
     {"scripts/idc_a.py": BARE_READ},
     {}, {"bare": ('scripts/idc_a.py:2: return f"gh gate check failed: '
                   '{proc.stderr.strip()[:200]}"',)}),

    ("a cut taken inside the door is a finding, and names its site",
     "The ordering rule's only positive example outside the canary — and the arm that "
     "reports it was also measured green-with-a-planted-leak.",
     {"scripts/idc_a.py": CUT_INSIDE_THE_DOOR},
     {}, {"truncations": ('scripts/idc_a.py:2: return f"gh gate check failed: '
                          '{CS.scrub(proc.stderr.strip()[:200])}"',)}),

    ("scripts/hooks/ is really walked, not just mentioned",
     "The file set is two globs and one of them can be deleted. On its own that trips "
     "the count floor — but the floor is a number in R28 that can be lowered in the same "
     "edit, and the pair was measured to hide a bare read in a hooks module with both "
     "gates green. A violation that only exists under hooks/ cannot be hidden that way.",
     {"scripts/idc_a.py": SCRUBBED_READ, "scripts/hooks/idc_h.py": BARE_READ},
     {}, {"bare": ('scripts/hooks/idc_h.py:2: return f"gh gate check failed: '
                   '{proc.stderr.strip()[:200]}"',)}),

    ("an exemption covers the line it names, and NOT the rest of its module",
     "Keyed on `(module, line)`. Key it on the module alone — a one-line edit that looks "
     "like a simplification — and every read in a module with one exemption becomes "
     "exempt. That was measured: a bare read planted in idc_gh_board.py, both gates green.",
     {"scripts/idc_gh_board.py": CLASSIFIED_READ + "\n" + BARE_READ},
     {RATE_LIMIT_KEY: REASON},
     {"bare": ('scripts/idc_gh_board.py:8: return f"gh gate check failed: '
               '{proc.stderr.strip()[:200]}"',)}),

    ("an exemption that matches no read at all is stale",
     "The other half of \"fail closed both ways\": an allowlist entry that outlives its "
     "site is how the list rots into a blanket pass. The refactor that does it is "
     "ordinary — the read moves into a helper and the exemption stays behind.",
     {"scripts/idc_gh_board.py": SCRUBBED_READ},
     {RATE_LIMIT_KEY: REASON},
     {"stale": ("scripts/idc_gh_board.py: if _is_rate_limit_stderr(p.stderr):",)}),

    ("an exemption that matches TWO reads is ambiguous, and both are named",
     "The hole this round found. One exemption is one person's judgement about one line; "
     "two reads sharing a key means that judgement silently covers a read nobody looked "
     "at. Two byte-identical lines do it on every interpreter, and on Python 3.9.6 — "
     "`/usr/bin/python3` here — two DIFFERENT lines inside one multi-line f-string do it "
     "too. Both sites must be named, because the fix is to tell them apart.",
     {"scripts/idc_gh_board.py": CLASSIFIED_READ + "\n" + CLASSIFIED_READ.replace(
         "def is_rate_limited(p):", "def also_rate_limited(p):")},
     {RATE_LIMIT_KEY: REASON},
     {"ambiguous": ("scripts/idc_gh_board.py:2: if _is_rate_limit_stderr(p.stderr):",
                    "scripts/idc_gh_board.py:8: if _is_rate_limit_stderr(p.stderr):")}),
)

for label, _why, modules, allowed, want in JUDGEMENTS:
    got = verdict_of(modules, allowed)
    expected = {arm: want.get(arm, ()) for arm in SC.Verdict.ARMS}
    ok = check(got == expected,
               "%s\n      expected %r\n      got      %r" % (label, expected, got))
    say(ok, label)

# A module the census cannot DECODE never reaches the parser, so `analyze`'s refusal
# cannot catch it. Until this was wrapped it escaped `census()` as a bare traceback and
# R28's sentence — the one that explains why an unreadable module is a refusal and never
# a skip — never printed. Loud either way; the operator just got a stack trace instead of
# the reason.
UNDECODABLE_TREE = tree({"scripts/idc_binary.py":
                         b"detail = p.stderr  # \xff\xfe not utf-8\n"})
try:
    SC.census(UNDECODABLE_TREE)
    check(False, "a module that is not valid UTF-8 was not reported as a census failure")
    say(False, "a module that cannot be decoded is a named census failure")
except SC.ParseFailure as exc:
    say(check(exc.module == "scripts/idc_binary.py",
              "ParseFailure did not name the module"),
        "a module that cannot be decoded is a named census failure")


# ── PART THREE: R28's own program, over a tree with something planted in it ──────────
# Parts one and two prove the machinery. They cannot prove that R28 USES it: R28's arms,
# its count floors, its registry and its prose all live in a shell heredoc, and on the
# real tree every one of them is silent because the real tree is clean. Each of them was
# deleted in turn, with a real credential-leaking read planted in scripts/, and the suite
# reported success — four separate times.
#
# So this part runs R28's census program itself, lifted verbatim out of the file that
# runs it, against a root that IS the real tree (by symlink) with one violation added.
# Nothing here is a re-implementation; if the program changes, this runs the change.
# Comfortably above any floor R28 will sensibly carry. See battery_transcript().
BIG_ENOUGH = 100000


def r28_program():
    """R28's census program, lifted out of the suite file rather than copied."""
    text = open(SUITE_PATH, encoding="utf-8").read()
    opener, closer = "<<'PYR28'", "\nPYR28\n"
    if text.count(opener) != 1 or text.count(closer) != 1:
        raise AssertionError("R28's heredoc is no longer delimited exactly once by %r/%r "
                             "— this test can no longer find the program it is testing"
                             % (opener, closer))
    return text[text.index("\n", text.index(opener)) + 1:text.index(closer) + 1]


R28_PROGRAM = r28_program()
SUITE_TEXT = open(SUITE_PATH, encoding="utf-8").read()


def edited(source, edits, what):
    """Apply (anchor, replacement) pairs, each asserted to match EXACTLY ONCE.

    The same discipline the mutation battery runs under, applied to fixture construction:
    a fixture built on an anchor that quietly matched nothing tests the unmodified thing
    and passes, which is the most convincing kind of green there is.
    """
    for anchor, replacement in edits:
        hits = source.count(anchor)
        if hits != 1:
            raise AssertionError("%s: anchor matched %d times, not once: %r"
                                 % (what, hits, anchor))
        source = source.replace(anchor, replacement)
    return source


def mirror(extra=None, edits=None, suite_edits=None):
    """A root indistinguishable from the real one to the census, plus what you plant.

    Every shipped module arrives as a SYMLINK, so this costs no copying and cannot drift
    from the tree it mirrors; `edits` replaces named modules with rewritten copies, and
    `extra` adds new ones. The suite file comes along because R28 reads it to check that
    its own battery is still being run.
    """
    root = scratch_dir("mirror")
    for sub in ("scripts/hooks", "tests/smoke"):
        os.makedirs(os.path.join(root, *sub.split("/")))
    edits = edits or {}
    for path in (sorted(glob.glob(os.path.join(PLUGIN, "scripts", "*.py")))
                 + sorted(glob.glob(os.path.join(PLUGIN, "scripts", "hooks", "*.py")))):
        rel = os.path.relpath(path, PLUGIN)
        dest = os.path.join(root, *rel.split("/"))
        if rel in edits:
            with open(dest, "w", encoding="utf-8") as handle:
                handle.write(edited(open(path, encoding="utf-8").read(), edits[rel], rel))
        else:
            os.symlink(path, dest)
    for rel, source in (extra or {}).items():
        with open(os.path.join(root, *rel.split("/")), "w", encoding="utf-8") as handle:
            handle.write(textwrap.dedent(source).strip() + "\n")
    suite = os.path.join(root, "tests", "smoke", "phase11-honesty-repro.sh")
    if suite_edits is None:
        os.symlink(SUITE_PATH, suite)
    else:
        with open(suite, "w", encoding="utf-8") as handle:
            handle.write(edited(SUITE_TEXT, suite_edits, "the suite file"))
    return root


def battery_transcript(passed=BIG_ENOUGH, tallied=True, python=None):
    """A stand-in for this file's own output, which R28 reads back and floors.

    R28 keeps the battery's transcript and requires it to report enough passing
    assertions, because a battery that RUNS is not the same as a battery that still
    CONTAINS anything. These are fixture INPUTS — hand-made on purpose, so the floor can
    be shown a gutted run without this file having to run a gutted copy of itself.
    `passed` is a large number rather than the real tally because the real tally is not
    known until the last line of this file, long after these runs happen.
    """
    path = os.path.join(scratch_dir("battery"), "battery.txt")
    lines = ["  ok   (a hand-made transcript: a fixture input, not a real run)"]
    if tallied:
        lines.append("test_stderr_census: assertions_passed=%d python=%s"
                     % (passed, python or sys.version.split()[0]))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return path


def run_r28(root, lib=LIB_DIR, program=None, transcript=None):
    """Run R28's census program exactly as the suite runs it.

    `python3 - <root> <lib> <battery transcript>` — the same three arguments the heredoc
    is given by the shell line above it.
    """
    proc = subprocess.run([sys.executable, "-", root, lib,
                           transcript or lib_for("healthy-battery", battery_transcript)],
                          input=program or R28_PROGRAM,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True)
    return proc.returncode, proc.stdout


def mutant_lib(edits):
    """A copy of stderr_census.py with the walk or the judgement broken, on sys.path."""
    path = os.path.join(scratch_dir("lib"), "stderr_census.py")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(edited(open(MODULE_PATH, encoding="utf-8").read(), edits,
                            "stderr_census.py"))
    return os.path.dirname(path)


# The plant that appears in most of these: an ordinary-looking helper that puts a child's
# raw stderr into a returned message. It is the shape of F1/F20/F33/F35/F40, and it is the
# shape the verifier used to prove each broken arm was a real leak rather than a lost test.
LEAK_LINE = 'return f"gh gate check failed: {proc.stderr.strip()[:200]}"'
BARE_SENTENCE = "read WITHOUT passing through the scrub at the read"
CUT_SENTENCE = "TRUNCATED INSIDE the scrub call"
STALE_SENTENCE = "names a line that no longer exists"
AMBIGUOUS_SENTENCE = "covers MORE THAN ONE read"
# Two different floors, and keeping their names apart matters: one refuses an
# INTERPRETER the walk is not proven on, the other refuses a walk that came back with
# fewer FILES AND READS than the tree is known to hold.
INTERPRETER_FLOOR_SENTENCE = "only proven to give identical answers"
COUNT_FLOOR_SENTENCE = "it has to find at least"
CANARY_SENTENCE = "no longer answers the way it was hand-counted"
BATTERY_SENTENCE = "no longer runs tests/smoke/lib/test_stderr_census.py"
GUTTED_SENTENCE = "it has to pass at least"
NO_TALLY_SENTENCE = "did not report how many assertions it passed"
STALE_TALLY_SENTENCE = "the transcript is not this run's"

# Fixture roots, built once and reused by PART FOUR. `bare` deliberately plants inside a
# module that ALREADY holds an exemption, so the same tree also catches an exemption keyed
# on the module instead of the line.
FIXTURES = {
    "clean": lambda: mirror(),
    "bare": lambda: mirror(edits={"scripts/idc_gh_board.py": [
        ("def _is_rate_limit_stderr(", BARE_READ.strip() + "\n\n\ndef _is_rate_limit_stderr(")]}),
    "cut": lambda: mirror(extra={"scripts/idc_fixture_cut.py": CUT_INSIDE_THE_DOOR}),
    "hooks": lambda: mirror(extra={"scripts/hooks/idc_fixture_leak.py": BARE_READ}),
    # The exempted read refactored out of existence — and one correctly scrubbed read
    # planted to keep the count floor satisfied, so the STALE arm is what speaks rather
    # than the floor. (With the floor speaking, this fixture would prove nothing about
    # the registry.)
    "stale": lambda: mirror(
        edits={"scripts/idc_gh_board.py": [("if _is_rate_limit_stderr(p.stderr):",
                                            "if _is_rate_limit_stderr(_tail(p)):")]},
        extra={"scripts/idc_fixture_ok.py": SCRUBBED_READ}),
    # The exempted line, written a second time in the same module. One entry, two reads.
    "ambiguous": lambda: mirror(edits={"scripts/idc_gh_board.py": [
        ("def _is_rate_limit_stderr(",
         CLASSIFIED_READ.strip() + "\n\n\ndef _is_rate_limit_stderr(")]}),
    # The one-line edit that switches this whole battery off. The anchor carries the
    # line's trailing continuation because the same text also appears inside R28's own
    # self-check, and an anchor that matched twice would build a fixture nobody planned.
    "battery-off": lambda: mirror(suite_edits=[
        ('python3 "$HERE/lib/test_stderr_census.py" 2>&1 | tee',
         'true "$HERE/lib/test_stderr_census.py" 2>&1 | tee')]),
    # The quieter way to switch the battery off: leave the invocation exactly where it is
    # and read the wrong element of PIPESTATUS. Index 1 is tee's status and is 0 however
    # the battery ended, so `|| fail` never fires and a battery reporting failure scrolls
    # past as ordinary output. The word PIPESTATUS is still on the line, which is why
    # step (0) has to ask for the literal `${PIPESTATUS[0]}` and not for the word.
    "pipestatus": lambda: mirror(suite_edits=[
        ('[ "${PIPESTATUS[0]}" -eq 0 ]', '[ "${PIPESTATUS[1]}" -eq 0 ]')]),
    # A real unscrubbed read, in a module the NARROWED walk below never visits. On its
    # own this tree is a plain bare-read finding; paired with the narrowed file set it is
    # the only thing the count floors have ever been shown to catch.
    "unwalked-leak": lambda: mirror(extra={"scripts/idc_fixture_unwalked.py": BARE_READ}),
}
ROOTS = {}


def root_for(name):
    if name not in ROOTS:
        ROOTS[name] = FIXTURES[name]()
    return ROOTS[name]


# Three fixtures are libraries rather than trees: they prove R28 still CALLS the
# interpreter floor and the canary, and that its COUNT floors still stand between a walk
# that has gone quiet and a clean report — by giving R28 a census module that refuses, or
# one that has stopped looking at part of scripts/, and requiring R28 to say so.
FLOORLESS_LIB = lambda: mutant_lib([("MIN_PYTHON = (3, 9)", "MIN_PYTHON = (99, 0)")])
DRIFTED_LIB = lambda: mutant_lib([('    "scrubbed_reads": 10,', '    "scrubbed_reads": 11,')])
# The file set, narrowed. Any edit that shrinks it does the same damage; this is the one
# an independent reviewer used, and it keeps BOTH registry modules (idc_command_contract,
# idc_gh_board) inside the walk on purpose, so the count floors are what speak and not the
# stale-exemption arm behind them.
NARROW_EDITS = (('sorted(glob.glob(os.path.join(root, "scripts", "*.py"))',
                 'sorted(glob.glob(os.path.join(root, "scripts", "idc_[cg]*.py"))'),)
NARROWED_LIB = lambda: mutant_lib(NARROW_EDITS)
LIBS = {}


def lib_for(name, build):
    if name not in LIBS:
        LIBS[name] = build()
    return LIBS[name]


# (label, why, root, lib, what the output MUST contain and how many times over).
# An empty `must` means the opposite claim: R28 has to come back CLEAN, exit 0.
END_TO_END = (
    ("the real tree, mirrored and untouched, is CLEAN",
     "The control, and the only one of these that could catch a census which refuses "
     "everything. It also proves the mirror is faithful — same modules, same reads, same "
     "registry — which is what makes the refusals below attributable to the plant.",
     "clean", None, ()),

    ("a bare read planted in scripts/ makes R28 REFUSE, and names it",
     "The verifier's own plant, in the verifier's own module. With R28's bare arm "
     "deleted, this exact tree came back clean from both gates. It is planted inside a "
     "module that already holds an exemption, so this tree also catches an exemption "
     "keyed on the module instead of the line.",
     "bare", None, ((BARE_SENTENCE, 1), ("scripts/idc_gh_board.py:", 1), (LEAK_LINE, 1))),

    ("a cut taken inside the door makes R28 REFUSE, and names it",
     "The ordering rule has no positive example anywhere in scripts/ — this is one, "
     "running through R28's arm rather than through the canary.",
     "cut", None, ((CUT_SENTENCE, 1),
                   ('scripts/idc_fixture_cut.py:2: return f"gh gate check failed: '
                    '{CS.scrub(proc.stderr.strip()[:200])}"', 1))),

    ("a violation under scripts/hooks/ makes R28 REFUSE",
     "Kills the two-edit fail-open: drop the hooks glob AND lower the count floors, and "
     "a bare read in a hooks module was measured invisible to both gates.",
     "hooks", None, ((BARE_SENTENCE, 1),
                     ("scripts/hooks/idc_fixture_leak.py:2: " + LEAK_LINE, 1))),

    ("an exemption whose line has gone makes R28 REFUSE",
     "Fail-closed the other way. The count floor is held level on purpose here — one "
     "correctly scrubbed read planted to replace the one refactored away — so that the "
     "STALE arm is what speaks and not the floor above it.",
     "stale", None, ((STALE_SENTENCE, 1),
                     ("if _is_rate_limit_stderr(p.stderr):", 1))),

    ("an exemption covering two reads makes R28 REFUSE, naming BOTH",
     "The hole this round closes. One approval, two reads — and on 3.9.6 the two reads "
     "need not even be the same line. Both sites must be named, twice over, because the "
     "fix is to tell them apart and a reader cannot do that from one of them.",
     "ambiguous", None, ((AMBIGUOUS_SENTENCE, 1),
                         ("covers scripts/idc_gh_board.py:", 2))),

    ("a suite that has stopped running this battery makes R28 REFUSE",
     "One word — `python3` to `true` — switches off every assertion in this file, and "
     "was measured to leave both gates green. R28 now reads its own source and refuses.",
     "battery-off", None, ((BATTERY_SENTENCE, 1),)),

    ("a suite that reads the WRONG element of PIPESTATUS makes R28 REFUSE",
     "The same switch-off, spelled as a typo. `${PIPESTATUS[1]}` is tee's status and is "
     "0 however the battery ended, so `|| fail` becomes a no-op — and the word PIPESTATUS "
     "is still sitting there, which is why step (0) waved this through, exit 0 and "
     "silent, until it was made to ask for the literal `${PIPESTATUS[0]}`. A guard "
     "protecting a rewrite whose whole thesis is that spelling is not structure had been "
     "written as a question about spelling.",
     "pipestatus", None, ((BATTERY_SENTENCE, 1),)),

    ("a census module that refuses this interpreter makes R28 REFUSE",
     "Proves R28 still CALLS check_interpreter: the floor is raised out of reach inside "
     "the module, and R28 has to relay the refusal. Deleting that call was measured green.",
     "clean", ("floorless", FLOORLESS_LIB), ((INTERPRETER_FLOOR_SENTENCE, 1),)),

    ("a walk that no longer tells the rules apart makes R28 REFUSE",
     "Same, for the canary — the layer R28's own prose calls load-bearing. Deleting "
     "R28's canary call was measured green, because this file runs the canary too; that "
     "is defence in depth, and defence in depth is not evidence.",
     "clean", ("drifted", DRIFTED_LIB), ((CANARY_SENTENCE, 1),)),

    ("a walk that has stopped looking at part of scripts/ makes R28 REFUSE",
     "The count floors were the LAST arm of R28 with no positive example, and the prose "
     "above this table claimed for two rounds that they had one. An independent reviewer "
     "disabled them and watched all 64 assertions stay green; then, with them off and the "
     "file set narrowed, a real unscrubbed read planted in a module the narrowed walk no "
     "longer visits came back CLEAN, exit 0, silent transcript. This is that experiment, "
     "run forwards: the walk is narrowed, the leak is really there, and the floors are "
     "the only thing left that can notice. They are not a parity check — finding MORE is "
     "not a hazard — they are the guard against a walk that has quietly gone quiet.",
     "unwalked-leak", ("narrowed", NARROWED_LIB), ((COUNT_FLOOR_SENTENCE, 1),)),

    ("a battery that has been GUTTED makes R28 REFUSE",
     "The third storey. R28 proves this file still runs; nothing proved it still "
     "contains anything. Emptying its fixture tables — one line each — leaves it exiting "
     "0 with a shorter transcript, and all five emptied at once was measured to leave "
     "BOTH gates green. R28 now floors the tally this file prints.",
     "clean", None, ((GUTTED_SENTENCE, 1),), battery_transcript(passed=3)),

    ("a battery that has stopped reporting its tally makes R28 REFUSE",
     "The floor is only as good as the number it reads. Deleting the tally line is a "
     "quieter way to remove the floor than deleting the floor, so it fails too.",
     "clean", None, ((NO_TALLY_SENTENCE, 1),), battery_transcript(tallied=False)),

    ("a battery transcript from another interpreter makes R28 REFUSE",
     "A transcript left over from an earlier run, or written by hand, would satisfy any "
     "floor. The tally carries the Python that produced it and R28 requires it to be the "
     "one it is running on.",
     "clean", None, ((STALE_TALLY_SENTENCE, 1),),
     battery_transcript(python="3.0.0-not-this-one")),
)

print("  -- R28's own program, against fixture trees --")
for entry in END_TO_END:
    label, _why, root_name, lib_spec, must = entry[:5]
    transcript = entry[5] if len(entry) > 5 else None
    lib = LIB_DIR if lib_spec is None else lib_for(*lib_spec)
    code, output = run_r28(root_for(root_name), lib, transcript=transcript)
    if not must:
        ok = check(code == 0, "%s: exit %d\n      %s" % (label, code, output.strip()))
    else:
        missing = ["%r %d time(s), saw %d" % (needle, times, output.count(needle))
                   for needle, times in must if output.count(needle) < times]
        ok = check(code != 0 and not missing,
                   "%s\n      exit %d; the refusal did not say %s\n      got: %s"
                   % (label, code, "; ".join(missing) or "(it did not refuse at all)",
                      output.strip()))
    say(ok, label)


# ── PART FOUR: the mutations ─────────────────────────────────────────────────────────
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


def decode_failure_trips(mutant):
    """The mutant must stop treating an UNDECODABLE module as a failure.

    Separate from the parse refusal on purpose: a file that is not valid UTF-8 never
    reaches the parser at all, so `analyze`'s refusal cannot catch it and the only thing
    standing there is the one in `census()`.
    """
    try:
        mutant["census"](UNDECODABLE_TREE)
    except mutant["ParseFailure"]:
        raise AssertionError("the read refusal still raised — the mutation changed nothing")
    return "a module that is not UTF-8 was skipped, so the census clears what it cannot read"


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

    ("deletion", "skip a module that cannot be DECODED instead of failing",
     '            raise ParseFailure(module, "unreadable: %s: %s" '
     '% (type(exc).__name__, exc))',
     "            continue",
     decode_failure_trips),

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
        say(True, "RED  [%s] %s\n          => %s" % (kind, what, observed))
    except AssertionError as exc:
        check(False, "[%s] %s stayed GREEN: %s" % (kind, what, exc))
        say(False, "GREEN [%s] %s — %s" % (kind, what, exc))

# ── PART FOUR, SECOND HALF: the guards only a fixture tree can watch ─────────────────
# The battery above breaks the WALK and lets the canary notice. Nothing it does can reach
# the judgement or R28 itself, because neither of those has a canary and neither of them
# says anything at all about a clean tree. These break them anyway, and require the
# fixture tree that watches each one to stop saying its sentence.
#
# Note what "RED" means here and what it does not. Four of these disable an arm of R28,
# and R28's backstop then refuses anyway — so the SUITE still goes red, with a blunter
# message. That is the backstop doing its job, and it is reported below rather than
# hidden: a downgraded sentence is a real loss even when the exit code is unchanged. The
# rest come back CLEAN, with the planted leak sitting in the tree, which is exactly the
# state an independent verifier reached six times before any of this existed.
#
# WHICH OF THE TWO HAPPENED IS ASSERTED, not merely printed. The criterion for a good
# mutation used to be "the sentence stopped being said" and nothing else — so a mutation
# that broke R28's program for an unrelated reason (a NameError, a stray syntax error)
# would produce output without the sentence and be recorded as a clean RED. The mutation
# would have proved nothing about the guard it names, and it would have looked exactly
# like the ones that do. Every row therefore carries the outcome it is expected to
# produce, hand-written from what the mutation should mean, and a row that crashes the
# program can no longer pass at all. All fifteen behaved as written when this was added,
# so it was latent rather than live — which is the whole family this round is about.
CRASH_MARKERS = ("Traceback (most recent call last):", 'File "<stdin>", line ')


def outcome(code, output):
    """(tag, the line to print). Three tags, and only two of them may be expected:

    "clean"   — R28 walked the planted tree and reported nothing wrong with it.
    "refused" — R28 refused anyway: the backstop, or an arm the mutation did not reach.
    "crashed" — the program never got as far as a verdict, so this mutation says nothing
                about the guard it was aimed at. Never expected; always a failure.
    """
    lines = [line for line in output.strip().splitlines() if line.strip()]
    if any(marker in output for marker in CRASH_MARKERS):
        return "crashed", "R28's program did not reach a verdict: %s" % (
            lines[-1][:96] if lines else "(silent)")
    if code == 0:
        return "clean", "R28 reported the tree CLEAN, and no other layer noticed"
    return "refused", "the backstop refused instead: %s" % (
        lines[0][:96] if lines else "(silent)")


# (class, what is broken, the fixture that watches it, edits to the census module, edits
#  to R28's program, the sentence that must stop being said, the outcome that must then
#  follow — "refused" where R28's backstop still speaks, "clean" where nothing does)
E2E_MUTATIONS = (
    ("deletion", "R28 stops reporting bare reads", "bare", (),
     (("if bare:\n    sys.exit(", "if False:\n    sys.exit("),), BARE_SENTENCE, "refused"),

    ("deletion", "R28 stops reporting cuts taken inside the door", "cut", (),
     (("if scan.truncations:\n    sys.exit(", "if False:\n    sys.exit("),),
     CUT_SENTENCE, "refused"),

    ("deletion", "R28 stops reporting stale exemptions", "stale", (),
     (("if stale:\n    sys.exit(", "if False:\n    sys.exit("),),
     STALE_SENTENCE, "refused"),

    ("deletion", "R28 stops reporting an exemption that covers two reads", "ambiguous", (),
     (("if ambiguous:\n    sys.exit(", "if False:\n    sys.exit("),),
     AMBIGUOUS_SENTENCE, "refused"),

    ("deletion", "R28 stops checking that this battery is still being run", "battery-off",
     (), (('if (len(runs_battery) != 1 or "|| fail" not in guard\n'
           '        or "${PIPESTATUS[0]}" not in guard):', "if False:"),),
     BATTERY_SENTENCE, "clean"),

    ("deletion", "R28 stops asking the interpreter floor", "clean",
     (("MIN_PYTHON = (3, 9)", "MIN_PYTHON = (99, 0)"),),
     (("    SCAN.check_interpreter()\n", "    pass\n"),),
     INTERPRETER_FLOOR_SENTENCE, "clean"),

    # The one this round exists for. The lib edit is the SITUATION (a walk that has
    # stopped looking at part of scripts/, with a real leak sitting in the part it no
    # longer looks at); the program edit is the MUTATION. Take the floors away and R28
    # reports that tree clean — which is the reviewer's result, reproduced here so it
    # runs on every suite run instead of living in a report.
    ("deletion", "R28 stops flooring how many files and reads the census must find",
     "unwalked-leak", NARROW_EDITS,
     (("if len(scan.modules) < FLOOR_FILES or len(scan.reads) < FLOOR_READS:",
       "if False:"),), COUNT_FLOOR_SENTENCE, "clean"),

    ("deletion", "R28 stops running the canary", "clean",
     (('    "scrubbed_reads": 10,', '    "scrubbed_reads": 11,'),),
     (("    SCAN.run_canary()\n", "    pass\n"),), CANARY_SENTENCE, "clean"),

    ("substitution", "the exemption is keyed on the MODULE instead of the line", "bare",
     (("            if read.key not in allowed_raw and not read.scrubbed]",
       "            if read.module not in {m for m, _ in allowed_raw} "
       "and not read.scrubbed]"),), (), BARE_SENTENCE, "clean"),

    ("deletion", "judge() stops noticing an exemption that matched nothing", "stale",
     (("    stale = sorted(set(allowed_raw) - set(matched))", "    stale = []"),), (),
     STALE_SENTENCE, "clean"),

    ("deletion", "judge() stops noticing an exemption that matched twice", "ambiguous",
     (("    ambiguous = [(key, matched[key]) for key in sorted(matched) "
       "if len(matched[key]) > 1]", "    ambiguous = []"),), (),
     AMBIGUOUS_SENTENCE, "clean"),

    ("deletion", "census() throws away the cuts analyze handed it", "cut",
     (("        truncations.extend(found_cuts)", "        truncations.extend([])"),), (),
     CUT_SENTENCE, "clean"),

    ("substitution", "census() reports every read as scrubbed", "bare",
     (("        reads.extend(found_reads)",
       '        reads.extend([setattr(r, "scrubbed", True) or r for r in found_reads])'),),
     (), BARE_SENTENCE, "clean"),

    ("deletion", "R28 stops putting a floor under how much the battery still contains",
     "clean", (),
     (('if int(fields["assertions_passed"]) < FLOOR_ASSERTIONS:', "if False:"),),
     GUTTED_SENTENCE, "clean", battery_transcript(passed=3)),

    ("value", "the file set drops scripts/hooks/ AND the floors are lowered to match",
     "hooks",
     (('(os.path.join(root, "scripts", "*.py"))\n                  '
       '+ glob.glob(os.path.join(root, "scripts", "hooks", "*.py")))',
       '(os.path.join(root, "scripts", "*.py")))'),),
     (("FLOOR_FILES, FLOOR_READS = 62, 25", "FLOOR_FILES, FLOOR_READS = 1, 1"),),
     BARE_SENTENCE, "clean"),
)

print("  -- the judgement and R28 itself, broken one guard at a time --")
for entry in E2E_MUTATIONS:
    kind, what, root_name, lib_edits, program_edits, sentence, expected = entry[:7]
    transcript = entry[7] if len(entry) > 7 else None
    try:
        lib = mutant_lib(lib_edits) if lib_edits else LIB_DIR
        program = edited(R28_PROGRAM, program_edits, "R28's program") if program_edits \
            else None
        code, output = run_r28(root_for(root_name), lib, program, transcript)
        if sentence in output:
            raise AssertionError("the refusal survived the mutation, so the fixture that "
                                 "is supposed to be watching this guard is not what "
                                 "catches it — the pair proves nothing")
        tag, said = outcome(code, output)
        if tag != expected:
            raise AssertionError("the sentence stopped, but R28 came back %r where this "
                                 "mutation is written down as %r — so what was observed "
                                 "is not what this row claims to demonstrate: %s"
                                 % (tag, expected, said))
        say(True, "RED  [%s] %s\n          => %s" % (kind, what, said))
    except AssertionError as exc:
        check(False, "[%s] %s stayed GREEN: %s" % (kind, what, exc))
        say(False, "GREEN [%s] %s — %s" % (kind, what, exc))

# THE TALLY, in a shape a shell can read. R28 floors it — see step (0b) there for why a
# battery that runs is not the same as a battery that still contains anything. The
# interpreter is stamped alongside so a transcript left over from another run, or from
# another Python, cannot be mistaken for this one's.
print("test_stderr_census: assertions_passed=%d python=%s"
      % (PASSED[0], sys.version.split()[0]))
if failures:
    print("\ntest_stderr_census: %d FAILED" % len(failures))
    for message in failures:
        print("  - %s" % message)
    sys.exit(1)
print("test_stderr_census: OK (Python %s) — %d assertions"
      % (sys.version.split()[0], PASSED[0]))
