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
Three things, in the order they must run:

  1. `check_interpreter()` — refuse an interpreter this walk is not proven on.
  2. `run_canary()`        — prove, on a fixture with a known answer, that the walk
                             still tells the rules apart ON THIS interpreter.
  3. `census(root)`        — the real walk, over the real tree.

Step 2 is not ceremony. On today's clean tree the ordering rule's true answer is ZERO,
so a walk that has stopped detecting truncation-inside-the-door produces byte-identical
output to a working one, and the suite reports success. The canary is the only place
that rule has a positive example, so it is the only thing standing between "clean" and
"blind". See R28's prose for the experiment that established this.
"""
import ast
import glob
import os
import sys

# ── THE RULES, as constants ──────────────────────────────────────────────────────────
# The oldest interpreter this walk is PROVEN identical on. 3.9 and not 3.8, because 3.9
# is where `x[:200]`'s shape settled: on 3.8 a plain index like `d["k"]` still arrives
# wrapped in an extra `ast.Index` node, which changes what the truncation check below is
# looking at — and changing it in the direction that finds FEWER violations, silently.
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
    reformatting that line breaks the key; that brittleness is the guard, not a defect
    in it. Every reformatting of an exempted line was tried, and each one fires either
    "this read is now bare" or "this exemption names a line that no longer exists" —
    never silence. A key made of node positions instead would be silent, and worse: the
    positions of anything inside an f-string MOVE between Python 3.9 and 3.10.
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
    except SyntaxError as exc:
        raise ParseFailure(module, "%s (line %s)" % (exc.msg, exc.lineno))
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
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        modules.append(module)
        found_reads, found_cuts = analyze(source, module)
        reads.extend(found_reads)
        truncations.extend(found_cuts)
    return Census(modules, reads, truncations)


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
