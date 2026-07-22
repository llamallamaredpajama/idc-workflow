# Proposal — parse the stderr census instead of pattern-matching it

**Status:** proposal, unimplemented. Written 2026-07-21 for independent analysis.
**Author's stake:** I wrote none of the census; I drove the review relay that shipped it (PR #163,
merged `6f246f6`). I have an obvious bias toward "the guard I just hardened should be hardened
further" — weigh accordingly.

**Verdict I am asking you to test, not accept:** the R28 stderr census should stop reading Python
source as text and start reading it as a parse tree, using the standard library's `ast`. No new
dependency. This is a test-hardening change, **not** a fix for any known live defect.

---

## 0. TL;DR for the analyst

| | |
|---|---|
| **What** | Rewrite the census in `tests/smoke/phase11-honesty-repro.sh:2127–2360` (234 lines) to walk a Python parse tree instead of matching text line-by-line. |
| **Why** | The census is the single chokepoint guarding the credential-leak class (F1/F20/F33/F35/F40). It has already been fooled once — see §2. It is currently a hand-written parser with the failure modes of one. |
| **Cost** | Nothing to install. `ast` is stdlib. Estimated ~40–60 lines replacing ~234, though the exemption registry and the two-sided proof stay. |
| **Risk** | `ast` node APIs drift across Python versions and **CI's `python3` is unpinned** (§5.2). This is the one thing most likely to kill it. |
| **Not proposed** | tree-sitter (§4). Any change to shipped `scripts/` code. Any change to markdown or shell checking. |
| **Kill criteria** | §7. If any hold, drop it — the current census is green and no defect is open against it. |

---

## 1. What exists today

`tests/smoke/phase11-honesty-repro.sh`, case **R28** (line 2110 onward), enforces one rule:

> Every read of a child process's `stderr` must pass through the credential scrub **at the read**,
> or be registered in an exemption table with a reason.

It is fail-closed in both directions: a new unscrubbed read fails the suite, **and** an exemption
naming a line that no longer exists fails the suite (so the allowlist cannot rot into a blanket
pass). That two-sided design is good and this proposal keeps it.

The implementation is text matching over source:

| Mechanism | Location | What it does |
|---|---|---|
| `READ` regex | `:2199` | `(?<![\w.])(\w+)\.stderr\b` — finds a `.stderr` read |
| substring test | `:2220` | `if "scrub" not in line` — decides the line is safe |
| `SLICE` regex | `:2252` | `\[:\s*\d+\s*\]` — finds a truncation |
| `scrub_argument()` | `:2256` | hand-written parenthesis counter extracting the scrub call's argument |
| `ALLOWED_RAW` | `:2203` | exemptions keyed on the **exact stripped source line** |

Iteration is `for lineno, raw in enumerate(open(path))` — strictly one line at a time.

---

## 2. Why this is worth questioning: the census was already fooled

This is the load-bearing argument. Everything else is secondary.

The ordering bug (fixed 2026-07-20 in `dfac050` / `9bb6357`) was: four sites truncated **before**
scrubbing — `scrub(x.strip()[:200])` instead of `scrub(x).strip()[:200]`. Four of six credential
rules are prefix-anchored and survive a tail cut; two are not (a PEM block's `-----END …-----`, and
the `@host` closing a URL userinfo). A cut landing before the closing anchor deletes the thing the
rule keys on, and the secret walks through the open door.

**The census could not see it**, because asking "does the token `scrub` appear on this line?" cannot
distinguish those two spellings. The fix was to add the parenthesis counter at `:2256` — i.e. the
response to "our text matching was too weak" was **to hand-write more parser**. That is the moment
worth re-examining.

Compounding it, the same round found the fix's *test* used a `ghp_` fixture the old code already
redacted — so it passed while `password=` and `Authorization: Basic` still leaked. A weak checker
and a non-discriminating fixture, on the same guard, in the same change.

---

## 3. The proposal

Replace the text matching with a parse-tree walk. Same rule, same exemption registry, same
two-sided failure, same error messages.

Working demonstration, run 2026-07-21 against the merged tree — this is real output, not a sketch:

```
files parsed        : 62
child .stderr reads : 25
cut-inside-scrub    : 0
```

**25 independently reproduces the count `fix-reviewer-4` arrived at by hand** ("25 stderr read sites
(exact)"), and 0 confirms the ordering fix holds. Demo source is in §8.

What becomes structurally impossible rather than merely unlikely:

| Today's weakness | Under a parse tree |
|---|---|
| A read split across lines is invisible (line-by-line iteration) | Expressions are nodes; line breaks are irrelevant |
| `"scrub" not in line` is satisfied by the word appearing in a trailing comment | Comments are not in the tree at all |
| `SLICE` only matches a literal integer, so `[:MAX_TAIL]` is missed | Any `Subscript` node is a subscript regardless of spelling |
| The paren counter has no string awareness; a `)` inside a quoted string mis-counts | Strings are `Constant` nodes; nesting is already resolved |
| `ALLOWED_RAW` keys on an exact stripped source line, so reformatting breaks it | Can key on module + qualified function + node position |

**Verified vs. inferred — read this before you trust the table.** Every "today's weakness" above is
read directly from the source at the cited lines and is *mechanically evident*. I did **not** build a
failing case for each. Treat them as claims to reproduce, not findings. §6.1 gives the commands.

---

## 4. Why not tree-sitter (the question that started this)

The idea arrived as "should we use tree-sitter?" The honest answer is that the *instinct* was right —
this workflow does structural analysis with text matching — but tree-sitter is the wrong instrument
for this particular target.

- **Python is already parseable for free.** `ast` is stdlib, exact for the language it parses, and
  needs no install step on any machine.
- **tree-sitter is a native dependency**, needed on the dev machine *and* on CI. `.github/workflows/ci.yml:11`
  runs `ubuntu-latest` and installs exactly one thing (`pyyaml`, `:27`). This repo lost **12+
  consecutive CI runs on main** to a dev-machine-vs-runner difference, fixed only 2026-07-19 in
  PR #164. Adding a compiled dependency to the suite reopens that exact wound.
- **tree-sitter's real advantages don't apply here.** Error-tolerant parsing (we control the source
  and it always parses), incremental reparse (we run once, cold), multi-language (this target is
  Python only).

tree-sitter would be the *only* option for structural checks over **markdown** playbooks and **shell**
tests, where no stdlib parser exists. Deliberately out of scope: `scripts/lint-references.sh` (314
lines of grep/awk, zero fence-awareness) handles markdown by convention instead — backticks mark text
as not-a-reference, documented at `:29`. Crude, free, and passing. Ten-plus `idc-assert-class: doc`
test files do the same. Replacing working convention with a dependency is gold-plating. **If someone
later wants markdown + shell + yaml checked structurally as one system, that is when tree-sitter
earns a real hearing** — and it should be argued on its own, not smuggled in behind this.

---

## 5. Risks and costs

### 5.1 A parse failure must FAIL, not skip
The §8 demo does `except SyntaxError: continue`. **That is a silent fail-open** and would be the same
defect class the census exists to prevent — an unparseable module would simply vanish from the census
and report clean. Any real implementation must treat a parse failure as a census failure. Flagging my
own demo's flaw because it is precisely the trap this codebase keeps falling into.

### 5.2 Python version drift — the most likely killer
`ast` node shapes change across versions (`ast.Index` removed in 3.9; `ast.Num`/`ast.Str` deprecated
then removed in favour of `ast.Constant`; pattern-matching nodes added in 3.10). Local is **3.14.3**.
**CI's `python3` is unpinned** — `ci.yml` has no `setup-python` step, so it takes whatever
`ubuntu-latest` ships, which changes under us. A tree walk written against 3.14 semantics could pass
locally and fail, *or silently under-match*, on the runner. Silent under-matching is the dangerous
half: it fails open. **Analyst: quantify this before anything else.** Mitigations to weigh — stick to
node types stable since 3.8; assert a minimum version at the top of the case; or pin `setup-python`
(which is a broader repo decision, not this proposal's to make).

### 5.3 It touches a freshly-reviewed guard
This code went through four adversarial rounds three days ago. Churning it re-opens surface that is
currently proven. The counter-argument: it is *test* code, the rule is unchanged, and the two-sided
proof plus the mutation battery are exactly what makes a rewrite verifiable.

### 5.4 Cost of the exemption registry
`ALLOWED_RAW` keyed on exact source lines is brittle *and* self-policing — brittleness is what makes
a stale exemption fail loudly. A node-based key is more robust but could be *too* forgiving (an
exemption surviving a rewrite of the line it exempts). **Do not assume node-keying is an improvement.**
Possibly keep the line-exact key precisely because it is brittle.

### 5.5 Readability
The current version is greppable by anyone. A tree walk needs a reader who knows what an AST is. This
repo's tests are unusually literate — matching that register is part of the work, not a nicety.

---

## 6. What "done" would have to mean here

The repo's standard, applied without discount:

1. **Red-when-broken, three mutation classes.** Deletion, value-corruption, substitution. Each
   mutation's anchor asserted to match **exactly once** before the result is trusted — a mutation that
   silently fails to apply manufactures a fake green, which has already happened once in this suite.
2. **Discriminating fixtures.** Every new case shown RED against the pre-change census, run from a
   `git archive` of the pre-change tree. The `ghp_` lesson: a fixture the old code already handled
   proves nothing.
3. **Parity before replacement.** The new census must reproduce today's result on today's tree —
   25 reads, 23 scrubbed, 2 exemptions, 0 ordering violations — *and* catch at least one case the old
   one provably misses (§6.1). Parity alone is not a reason to switch.
4. **Gates.** `bash scripts/lint-references.sh` exit 0; `bash tests/smoke/run-all.sh` exit 0, ALL
   GREEN, 75 PASS / 75 distinct / 0 FAIL, counted after the exit marker (**counting mid-run yields 74**
   — phase-governance is the last phase).
5. **No assertion weakened.** Branch record is tests `+2467/-0`, all non-test deletions verified
   non-weakening. Any rewrite must preserve that property.
6. **CI green on the Linux runner** — not just locally. Non-negotiable given §5.2.

### 6.1 Reproduce the claimed blind spots first
Before writing anything, confirm the weaknesses are real by planting each in a scratch copy of a
module and running the **current** census. It should report clean on all four:

- a `.stderr` read split across two lines;
- a raw `.stderr` read with a trailing comment containing the word `scrub`;
- a truncation written `[:MAX_TAIL]` (named constant) inside a scrub call;
- a scrub argument containing a string literal with an unbalanced `)`.

**If the current census already catches these, this proposal is substantially weaker and may be
dead.** Report that outcome honestly rather than proceeding.

---

## 7. Kill criteria — drop this if any hold

- The blind spots in §6.1 turn out not to be reachable (the census already catches them).
- Version drift (§5.2) cannot be neutralised without pinning CI's Python, and pinning is judged out
  of scope.
- The rewrite cannot be shown to catch anything the current one misses — parity-only is not a case.
- It cannot be expressed at a readability comparable to the surrounding suite.
- Anyone can show a live defect the *current* census misses that this rewrite would **also** miss —
  then the effort belongs on that defect instead.

---

## 8. The demonstration, verbatim

Run from the repo root on the merged tree. Note the `SyntaxError` fail-open flaw called out in §5.1 —
kept here exactly as run, so the analyst evaluates what actually produced the numbers.

```python
import ast, glob

def scrub_calls(tree):
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            f = n.func
            name = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            if name == "scrub":
                yield n

reads = sliced_inside = 0
files = sorted(glob.glob("scripts/*.py") + glob.glob("scripts/hooks/*.py"))
for path in files:
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except SyntaxError:
        continue                      # <-- §5.1: silent fail-open; must FAIL in a real version
    for n in ast.walk(tree):
        if isinstance(n, ast.Attribute) and n.attr == "stderr":
            if getattr(n.value, "id", "") != "sys":
                reads += 1
    for call in scrub_calls(tree):
        for arg in call.args:
            for sub in ast.walk(arg):
                if isinstance(sub, ast.Subscript):     # a cut INSIDE the scrub call
                    sliced_inside += 1
                    print(f"  ORDERING VIOLATION {path}:{call.lineno}")

print(f"files parsed        : {len(files)}")
print(f"child .stderr reads : {reads}")
print(f"cut-inside-scrub    : {sliced_inside}")
```

Observed 2026-07-21 on `6f246f6`: `62 / 25 / 0`.

Note the demo is deliberately naive — it counts `.stderr` attribute reads without the exemption
logic, `sys.stderr` filtering beyond the `id` check, or keyword-argument handling (`stderr=`). It
demonstrates feasibility and reproduces the hand count; it is not a candidate implementation.

---

## 9. Provenance

- Originating question: whether **tree-sitter** has a role in this workflow. The Research Wiki and
  Engineering Logbook contain **no** tree-sitter material (searched 2026-07-21, no matches), so there
  is no prior research behind the question and none behind this answer.
- Context for the census itself: `~/.claude/fix-runs/pr-163-completion-honesty-review-2026-07-20-0051/`
  — `review-3-codex.md` (F46, the fixture-already-handled finding), `round4-root-cause.md`,
  `review-4-final.md` (the hand count of 25 sites / 19 modules).
- Merged as `6f246f6`; census at `tests/smoke/phase11-honesty-repro.sh:2110–2360`.
