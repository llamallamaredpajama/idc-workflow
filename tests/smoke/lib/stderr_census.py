#!/usr/bin/env python3
"""The R28 stderr census, as a walk over the parse tree — the machinery only.

R28 in tests/smoke/phase11-honesty-repro.sh asserts one rule about every module under
scripts/:

    Every read of a child process's stderr passes through the credential scrub AT THE
    READ, or is registered in R28's ALLOWED_RAW with a reason. Where it does pass
    through, no truncation may happen INSIDE the scrub call.

This file finds the facts that rule is judged against. It does not judge them and it
never speaks: it returns records and raises typed errors. Every word of explanation —
the registry, its reasons, the failure prose somebody reads at 2am — stays in R28,
where the reviewer already is.

WHAT A PARSE TREE BUYS, for a reader who has never met one
----------------------------------------------------------
Python will hand you your own source as a *tree* instead of as a page of text. This
line —

    CS.scrub(p.stderr or "").strip()[:200]

— becomes, in words: a call to `strip`, on the result of a call to `CS.scrub`, whose
one argument is "the `stderr` of the thing called `p`, or else an empty string"; and
then, OUTSIDE all of that, a slice `[:200]`. Every relationship in that sentence —
what is inside what — is a fact about STRUCTURE, and the tree states it outright.

The census this replaces could only ask about SPELLING: does the word `scrub` appear
somewhere on this line? Is there a `[:` between the parentheses I counted by hand? The
two kinds of question give the same answer right up until somebody writes the same code
a different way — and then they part company SILENTLY. The check keeps passing and
stops looking. Four ways it had already gone blind, every one of them ordinary Python:

    subprocess.run(cmd, capture_output=True).stderr   # nothing but a `)` before the
                                                      # dot, so the pattern never saw
                                                      # this read at all
    scrubbed = CS.scrub(a)                            # the WORD "scrub" is on the line
    detail = f"{scrubbed} {p.stderr}"                 # ...and on this one too
    raw = p.stderr  # the caller already scrubs this  # ...and this one
    CS.scrub(p.stderr.strip()[:MAX_TAIL])             # a cut spelled with a name
                                                      # instead of a number, inside
                                                      # the door

None of those changes the structure, so none of them can hide from a tree.

WHAT THIS FILE OWES ITS CALLER
------------------------------
Four things, in the order they must run:

  1. `check_interpreter()` — refuse an interpreter this walk is not proven on.
  2. `run_canary()`        — prove, on a fixture with a known answer, that the walk
                             still tells the rules apart ON THIS interpreter.
  3. `census(root)`        — the real walk, over the real tree. Facts only.
  4. `judge(scan, allowed)`— those facts measured against R28's registry, and turned
                             into the four findings R28 has a sentence for.

Step 2 is not ceremony. On today's clean tree the ordering rule's true answer is ZERO,
so a walk that has stopped detecting truncation-inside-the-door produces byte-identical
output to a working one, and the suite reports success. The canary is the only place
that rule has a positive example, so it is the only thing standing between "clean" and
"blind". See R28's prose for the experiment that established this.

Step 4 exists because that lesson had to be learned TWICE. Round 5 gave the walk a
canary and stopped there — and an independent verifier then broke the layer ABOVE the
walk twenty-eight ways, found fourteen of them undetected, and proved six of those
fourteen would let a real planted credential leak through with both gates reporting
success. Every one of them lived in the judgement: `census()` throwing away what
`analyze()` found, or R28's verdict arms deciding not to look. A canary one function
below cannot see any of that. So the judgement is a function here, where a fixture tree
with a known-bad module can be pushed through it — and the fixtures that do so are in
test_stderr_census.py, which runs before R28 says anything about scripts/.
"""
import ast
import glob
import os
import sys

# ── THE RULES, as constants ──────────────────────────────────────────────────────────
# The oldest interpreter this walk is PROVEN identical on, and the reason is NOT the one
# this comment used to give. It said 3.8 wraps a plain index in an extra `ast.Index` node
# and so under-matches the truncation rule. That was inherited from the proposal and it
# was then MEASURED on a real CPython 3.8.20: a real cut is still `ast.Slice` there and an
# index is still not, so `isinstance(node.slice, ast.Slice)` gives 3.8 the same two answers
# it gives 3.14. Truncation count 0, every count identical, canary green. There is no
# under-match. The sentence was confident and false, which is worse than no sentence.
#
# What 3.8 actually gets wrong is the KEY. A read inside a multi-line f-string is reported
# at the f-string's OPENING line, not its own, so `_source_line` below derives the wrong
# text for it: 7 of the 25 keys on today's real tree are wrong on 3.8 — with every count
# perfect and the canary passing green. A wrong key is a wrong exemption, and that is the
# one thing here that fails quietly.
#
# The floor is at 3.9 rather than 3.9.7 DELIBERATELY, and it is a cost taken with open
# eyes: the same f-string collapse survives on 3.9.6 in its narrow form (a TRIPLE-QUOTED
# multi-line f-string whose replacement field carries a conversion `!r` or a format spec;
# fixed upstream in 3.9.7). 3.9.6 is `/usr/bin/python3` on this project's dev machine and
# the `python3` four of its five shells resolve to, so a floor of 3.9.7 would make this
# suite refuse to run in every agent and teammate pane. The residual hole — two reads
# collapsing onto one key, so one exemption silently covers a read nobody approved — is
# closed instead by `judge()` below, which fails the census when an exemption matches more
# than one read. That guard is version-independent and it also closes the same hole on
# every interpreter, where two byte-identical source lines in one module already collide.
MIN_PYTHON = (3, 9)

# The credential scrub, under every name it is called by in this repo: `CS.scrub` and
# `H.scrub` (the door, imported under two initials) and the drain's own `_scrub`. The
# match is on the callee's simple name and it is EXACT — `_scrub_later` is not the door,
# and a check that accepted it would be the old "is the word `scrub` on this line?" bug
# wearing a parse tree as a costume.
SCRUB_NAMES = frozenset(("scrub", "_scrub"))


# ── THE REFUSALS ─────────────────────────────────────────────────────────────────────
# Typed, and carrying data rather than sentences. R28 turns each of these into the prose
# that explains what it costs.
class CensusError(Exception):
    """Base class: something happened that makes a clean census unsafe to believe."""


class InterpreterTooOld(CensusError):
    """This walk is not proven on this Python, so its answer means nothing."""

    def __init__(self, minimum, running):
        CensusError.__init__(self, "census needs Python %d.%d+, got %s"
                                   % (minimum[0], minimum[1], running))
        self.minimum = minimum
        self.running = running


class ParseFailure(CensusError):
    """A module the census cannot read. Never a skip — see R28."""

    def __init__(self, module, detail):
        CensusError.__init__(self, "%s did not parse: %s" % (module, detail))
        self.module = module
        self.detail = detail


class CanaryDrift(CensusError):
    """The fixture with the known answer came back with a different answer."""

    def __init__(self, drift):
        CensusError.__init__(self, "canary drift: %r" % (drift,))
        self.drift = drift


# ── WHAT THE WALK FINDS ──────────────────────────────────────────────────────────────
class Site(object):
    """One place in one module, named so a person can go and look at it.

    `line` is the read's own source line, stripped — the same text R28's ALLOWED_RAW is
    keyed on, and deliberately so. Keying an exemption to a line of text means that
    reformatting that line breaks the key, and that brittleness is the guard rather than
    a defect in it. Four reformattings of a live exemption were tried against this walk
    and all four are LOUD: three come back as "this read is now bare", and deleting the
    site outright trips the count floor, with the stale-exemption check behind it. None
    is silent. A key made of node positions would be tidier and strictly worse — the
    positions of anything inside an f-string MOVE between Python 3.9 and 3.10, so a key
    computed on one interpreter would quietly miss on another.

    The one thing a text key cannot promise on its own is that it names ONE read. Two
    byte-identical source lines in a module derive the same key on every interpreter —
    scripts/hooks/idc_recirc_closeout_gate.py:395 and :414 are identical today, and are
    harmless only because neither is exempt — and on 3.9.6 two DIFFERENT lines inside one
    multi-line f-string collapse onto the opening line as well (see MIN_PYTHON above).
    Either way one exemption would cover two reads while its author approved one. That is
    what `judge()` refuses, and it is the only reason a text key is safe.
    """

    def __init__(self, module, lineno, line):
        self.module = module
        self.lineno = lineno
        self.line = line

    @property
    def key(self):
        """The ALLOWED_RAW key: (module relative path, the stripped source line)."""
        return (self.module, self.line)

    def where(self):
        return "%s:%d: %s" % (self.module, self.lineno, self.line)


class Read(Site):
    """A read of a child process's stderr. `scrubbed` says whether it happens inside
    an argument of the scrub door."""

    def __init__(self, module, lineno, line, scrubbed):
        Site.__init__(self, module, lineno, line)
        self.scrubbed = scrubbed


class Truncation(Site):
    """A cut taken INSIDE a scrub call that is handling a child's stderr — i.e. the
    door is handed a fragment. Two of the scrub's rules match on a CLOSING anchor (the
    PEM footer; the `@host` that ends a URL's userinfo), and a cut that removes the
    anchor removes the rule's only handle on the secret."""


class Census(object):
    """Everything one pass over the tree found."""

    def __init__(self, modules, reads, truncations):
        self.modules = modules            # every file globbed, relative to the root
        self.reads = reads                # every child-stderr read, in source order
        self.truncations = truncations    # every cut taken inside the door


# ── THE WALK ─────────────────────────────────────────────────────────────────────────
def _is_child_stderr_read(node):
    """Is this node a read of a CHILD process's stderr?

    Three conditions, and each one rules out a specific impostor:
      * an attribute access spelled `stderr`            — `<anything>.stderr`
      * being READ, not written                         — `fake.stderr = "x"` is a write
      * whose owner is not the name `sys`               — `sys.stderr` is our own

    A `stderr=subprocess.PIPE` keyword argument is not an attribute access at all, so it
    is excluded by construction — no special case, and no substring test that could
    accidentally skip a real read that happens to share the line with one.
    """
    return (isinstance(node, ast.Attribute)
            and node.attr == "stderr"
            and isinstance(node.ctx, ast.Load)
            and not (isinstance(node.value, ast.Name) and node.value.id == "sys"))


def _callee_name(call):
    """The simple name a call is made under: `CS.scrub` → "scrub", `_scrub` → "_scrub"."""
    func = call.func
    if isinstance(func, ast.Attribute):
        return func.attr
    if isinstance(func, ast.Name):
        return func.id
    return ""


def _handed_to(call):
    """Every node inside every argument of a call — positional and keyword alike.

    "Inside" is transitive: `CS.scrub(("a" + p.stderr).strip())` hands the door that
    read just as surely as `CS.scrub(p.stderr)` does, and both must count.
    """
    arguments = list(call.args) + [kw.value for kw in call.keywords]
    return [node for argument in arguments for node in ast.walk(argument)]


def _source_line(lines, node):
    """The node's own source line, stripped — the key format ALLOWED_RAW uses.

    A read written across several physical lines (`(p\\n.stderr)` — rare, and nobody's
    house style) collapses to a single-space join of those lines, so the key is still
    one line of text a person can read and paste.
    """
    first = node.lineno
    last = getattr(node, "end_lineno", None) or first
    if last <= first:
        return lines[first - 1].strip()
    return " ".join(" ".join(lines[first - 1:last]).split())


def analyze(source, module):
    """The one walk. Returns (reads, truncations) for a single module's source text.

    THE SAME function serves the canary and the real tree. That identity is the whole
    value of the canary: a fixture that exercises some other walk certifies nothing
    about the walk that actually runs.
    """
    try:
        tree = ast.parse(source)
    except Exception as exc:
        # ANY refusal from the parser, not only SyntaxError — a file carrying a stray
        # null byte raises ValueError instead. "The census could not read this module"
        # is the same answer however the parser chose to phrase it, and the one thing
        # that must never happen is for it to become a skip.
        raise ParseFailure(module, "%s: %s" % (type(exc).__name__, exc))
    lines = source.splitlines()

    # Pass one: the scrub calls. Two facts come out of each — which reads it covers,
    # and which cuts happen inside it.
    #
    # The truncation check is SCOPED to calls that are handling a child's stderr. An
    # unrelated `CS.scrub(banner[:80])` truncates nothing the credential rules care
    # about, and flagging it would train the reader to ignore the check.
    covered = set()
    cut_nodes = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or _callee_name(node) not in SCRUB_NAMES:
            continue
        handed = _handed_to(node)
        reads_here = [n for n in handed if _is_child_stderr_read(n)]
        if not reads_here:
            continue
        covered.update(id(n) for n in reads_here)
        for inner in handed:
            # `xs[:200]` and `xs[0:200]` are SLICES — a cut. `d["k"]` and `xs[0]` are
            # indexes; they select, they do not shorten, and they must not flag.
            if isinstance(inner, ast.Subscript) and isinstance(inner.slice, ast.Slice):
                cut_nodes[id(inner)] = inner

    # Pass two: every read, now that we know which ones the door covers.
    reads = [Read(module, node.lineno, _source_line(lines, node), id(node) in covered)
             for node in ast.walk(tree) if _is_child_stderr_read(node)]
    truncations = [Truncation(module, node.lineno, _source_line(lines, node))
                   for node in cut_nodes.values()]

    # `ast.walk` visits breadth-first, which is not an order anyone can read. Sort.
    reads.sort(key=lambda site: (site.lineno, site.line))
    truncations.sort(key=lambda site: (site.lineno, site.line))
    return reads, truncations


def source_files(root):
    """Every shipped Python module. Unchanged from the census this replaces: there are
    no .py files anywhere outside scripts/, scripts/hooks/ and tests/."""
    return sorted(glob.glob(os.path.join(root, "scripts", "*.py"))
                  + glob.glob(os.path.join(root, "scripts", "hooks", "*.py")))


def census(root):
    """Walk the whole shipped tree. Raises ParseFailure on the first unreadable module.

    A module that will not parse is NOT skipped. A skip would delete that module from
    the census and report clean — and the day one of these files uses syntax newer than
    the interpreter running the suite (a `match` statement under Python 3.9, say) that
    is exactly the shape the failure would take: quieter coverage, identical output.
    """
    modules, reads, truncations = [], [], []
    for path in source_files(root):
        module = os.path.relpath(path, root)
        try:
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
        except (OSError, UnicodeDecodeError) as exc:
            # Not every unreadable module reaches the parser. A file carrying a byte that
            # is not valid UTF-8 fails at the READ, before `analyze` has anything to try,
            # and until this was wrapped it escaped as a bare traceback — so R28's
            # sentence explaining why an unreadable module is a refusal never printed.
            # Loud either way, but the operator got a stack trace instead of the reason.
            raise ParseFailure(module, "unreadable: %s: %s" % (type(exc).__name__, exc))
        modules.append(module)
        found_reads, found_cuts = analyze(source, module)
        reads.extend(found_reads)
        truncations.extend(found_cuts)
    return Census(modules, reads, truncations)


# ── THE JUDGEMENT ────────────────────────────────────────────────────────────────────
# Everything above answers "what is there". This answers "what is wrong with it", which
# is a different question and needs the registry — and the registry lives in R28, so it
# arrives as an argument. Nothing here speaks: `judge` hands back four lists and R28 puts
# the sentences on them.
#
# Why this is a function at all, rather than nine lines inside R28 where it used to live:
# nine lines inside a shell heredoc cannot be handed a fixture. They can only ever be run
# against the one real tree — which is CLEAN, so all four of these lists are empty, so
# every one of these guards could be dead and the output would not move by a character.
# That is not a hypothesis. Somebody deleted each of these arms in turn, planted a real
# credential-leaking read in scripts/, and watched the whole suite report success four
# times over. It is the same shape as the ordering rule's zero-positive-examples problem
# that the canary exists for, one storey up, and it wants the same answer: a fixture with
# a known-bad module, pushed through the code that actually runs.
class Verdict(object):
    """The four things that can be wrong, once the registry has had its say.

    `bare`        — a child's stderr read raw, and nobody registered it. The finding.
    `ambiguous`   — one registry entry matching SEVERAL reads. Explained below.
    `stale`       — a registry entry matching NO read: an exemption outliving its site.
    `truncations` — a cut taken inside the door, so the door was handed a fragment.

    `bare` and `stale` are the two directions of "fail closed both ways": a new raw read
    fails, and so does an exemption that has stopped naming anything, which is what stops
    the registry rotting into a blanket pass.
    """

    def __init__(self, bare, ambiguous, stale, truncations):
        self.bare = bare
        self.ambiguous = ambiguous        # [(key, [Read, ...])], each with 2+ reads
        self.stale = stale                # [key]
        self.truncations = truncations

    ARMS = ("bare", "ambiguous", "stale", "truncations")

    @property
    def clean(self):
        return not any(getattr(self, arm) for arm in self.ARMS)

    def fired(self):
        """The names of the arms that found something, in the order R28 speaks them.

        R28 uses this as a BACKSTOP: after it has said its piece about each arm it asks
        whether anything is left unspoken, so that disabling one arm cannot turn a
        finding into silence — it can only downgrade the sentence.
        """
        return [arm for arm in self.ARMS if getattr(self, arm)]


def judge(scan, allowed_raw):
    """Measure what the walk found against R28's registry of registered raw reads.

    `allowed_raw` is keyed `(module relative path, exact stripped source line)` — see
    `Site.key`. Three rules, and the middle one is newer than the other two:

      * a read whose key is registered is EXEMPT, scrubbed or not;
      * a registered key must match AT LEAST one read, or the exemption is stale;
      * a registered key must match AT MOST one read, or the exemption is ambiguous.

    The at-most-one rule is the one nobody thought to write down. An exemption is a
    person's judgement about ONE line of code that they read and accepted. If two reads
    derive the same key, that single judgement silently covers a second read the author
    never saw — and the second one can be anything at all, including the raw read into a
    committed message this whole census exists to prevent. It happens two ways, both
    ordinary: two byte-identical lines in one module (true on every interpreter, and
    already true today at idc_recirc_closeout_gate.py:395 and :414 — harmless only
    because neither is registered), and, on Python 3.9.6 and 3.8, two different lines
    inside one multi-line f-string, which the parser reports at the same line number.
    Both were reproduced with a real unscrubbed read that the census cleared.

    So an exemption that covers more than one read is a FAILURE, and R28 names every site
    it covered — because the fix is to make the lines distinguishable again, and that
    needs the reader to see all of them.
    """
    matched = {}
    for read in scan.reads:
        if read.key in allowed_raw:
            matched.setdefault(read.key, []).append(read)
    bare = [read for read in scan.reads
            if read.key not in allowed_raw and not read.scrubbed]
    ambiguous = [(key, matched[key]) for key in sorted(matched) if len(matched[key]) > 1]
    stale = sorted(set(allowed_raw) - set(matched))
    return Verdict(bare, ambiguous, stale, list(scan.truncations))


# ── LAYER 1: THE FLOOR ───────────────────────────────────────────────────────────────
def check_interpreter(version=sys.version_info):
    """Refuse a Python this walk has never been proven identical on.

    `version` is a parameter only so the unit test can ask what happens on 3.8 without
    owning a 3.8. Nothing else should pass it.
    """
    if tuple(version[:2]) < MIN_PYTHON:
        raise InterpreterTooOld(MIN_PYTHON, "%d.%d.%d" % tuple(version[:3]))


# ── LAYER 2: THE CANARY ──────────────────────────────────────────────────────────────
# A fixture whose answer is known by hand, run through `analyze` — the same function the
# real tree goes through. Every rule appears here TWICE: spelled the way that must count,
# and spelled the way that must not. A walk that stops telling the two apart cannot come
# back with these numbers, whatever interpreter it is running on.
#
# Do not "fix" this fixture by re-deriving the expectations from it. The expectations are
# the hand-done work; the fixture is what they are checked against. Derive one from the
# other and the canary starts agreeing with whatever the walk currently does.
CANARY_MODULE = "<canary>"
CANARY_SOURCE = '''\
def canary(p, q, r, s, t, u, cmd, table, fake):
    # A variable NAMED for the door scrubs nothing: the word is on the line, the door
    # is not in the expression. This one line is the whole of the old census's (i) blind
    # spot, and the most natural variable name in the repo.
    scrubbed = CS.scrub(p.stdout or "")
    tail = scrubbed + " | " + p.stderr
    # Correct, in each of the three names the door is called by, with the cut OUTSIDE
    # it — spelled as a literal bound and as a named one.
    ok_literal = CS.scrub(q.stderr or "").strip()[:200]
    ok_named = H.scrub(q.stderr or "").strip()[:MAX_TAIL]
    ok_helper = _scrub(r.stderr or "")
    # Correct, and written across three lines. The census this replaces REJECTED this
    # shape — correct code, failed for the crime of not fitting on one line.
    ok_split = CS.scrub(
        r.stderr or ""
    ).strip()[:200]
    # Correct: an index selects, it does not shorten, so `table["stderr"]` must not
    # register as a cut even though it sits inside a door handling real stderr.
    ok_index = CS.scrub(table["stderr"] + s.stderr)
    # Correct, inside an f-string — the shape every hook writes its diagnostics in.
    ok_message = f"gh failed: {CS.scrub(s.stderr or '').strip()[:200]}"
    # Wrong, in the four spellings the cut reaches the inside of the door by: a literal
    # bound, a named bound, one hidden behind an unbalanced ")" in a string, and one
    # inside an f-string. Every one is a real ordering violation.
    bad_literal = CS.scrub(t.stderr.strip()[:200])
    bad_named = CS.scrub(t.stderr.strip()[:MAX_TAIL])
    bad_string = CS.scrub("gh failed :) " + u.stderr[0:200])
    bad_message = f"gh failed: {CS.scrub(u.stderr.strip()[: 200])}"
    # Raw: read straight off the call, so there is no word at all before the dot.
    chained = subprocess.run(cmd, capture_output=True).stderr
    # Raw: a trailing comment is not a scrub, however sincerely it is meant.
    commented = p.stderr  # the caller already runs this through the scrub door
    # Raw: a `stderr=` keyword sharing the line hides nothing.
    kwarg = subprocess.run(cmd, stderr=subprocess.PIPE).stderr
    # Raw: a callee whose NAME merely contains "scrub" is not the door.
    later = _scrub_later(q.stderr)
    # None of these three is a finding: a cut inside a door that is handling no child
    # stderr at all, a WRITE to an attribute, and our own process's stderr.
    unrelated = CS.scrub(p.stdout[:200] or "")
    fake.stderr = "no child ran"
    own = sys.stderr
    return (scrubbed, tail, ok_literal, ok_named, ok_helper, ok_split, ok_index,
            ok_message, bad_literal, bad_named, bad_string, bad_message, chained,
            commented, kwarg, later, unrelated, own)
'''

# Counted by hand against the fixture above, and then checked on seven interpreters from
# 3.9.6 to 3.14.3. The two tuples matter as much as the two numbers: totals alone would
# survive a walk that swapped a scrubbed read for a raw one.
CANARY_EXPECT = {
    "child_stderr_reads": 15,
    "scrubbed_reads": 10,
    "raw_reads": (
        'tail = scrubbed + " | " + p.stderr',
        'chained = subprocess.run(cmd, capture_output=True).stderr',
        'commented = p.stderr  # the caller already runs this through the scrub door',
        'kwarg = subprocess.run(cmd, stderr=subprocess.PIPE).stderr',
        'later = _scrub_later(q.stderr)',
    ),
    "truncations": (
        'bad_literal = CS.scrub(t.stderr.strip()[:200])',
        'bad_named = CS.scrub(t.stderr.strip()[:MAX_TAIL])',
        'bad_string = CS.scrub("gh failed :) " + u.stderr[0:200])',
        'bad_message = f"gh failed: {CS.scrub(u.stderr.strip()[: 200])}"',
    ),
}


def canary_result():
    """What `analyze` makes of the fixture, in the shape CANARY_EXPECT is written in."""
    reads, truncations = analyze(CANARY_SOURCE, CANARY_MODULE)
    return {
        "child_stderr_reads": len(reads),
        "scrubbed_reads": len([r for r in reads if r.scrubbed]),
        "raw_reads": tuple(r.line for r in reads if not r.scrubbed),
        "truncations": tuple(t.line for t in truncations),
    }


def run_canary():
    """Raise CanaryDrift unless the fixture still answers exactly as hand-counted.

    The drift it carries is {name: (expected, got)} — enough for R28 to say which rule
    stopped working, which is the difference between a repairable failure and a shrug.
    """
    got = canary_result()
    drift = {name: (expected, got[name])
             for name, expected in CANARY_EXPECT.items() if got[name] != expected}
    if drift:
        raise CanaryDrift(drift)
