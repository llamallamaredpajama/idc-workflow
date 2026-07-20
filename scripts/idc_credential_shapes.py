"""idc_credential_shapes.py — the ONE table of credential shapes, in TWO PROVENANCE PROFILES.

WHY THIS EXISTS. Two IDC surfaces scrub credentials out of text before it is written down:
`idc_live_check.py` (a verify command's captured output, on its way into a committed evidence record)
and `idc_intake_manifest.py` (human prose lifted out of an external document, on its way into a
manifest). They were written independently and had DRIFTED IN BOTH DIRECTIONS — each caught real
credential shapes the other missed, so which secrets got redacted depended on which door the text
happened to walk through. The live check knew Google API keys, Google OAuth tokens, JWTs, PEM private
keys and `scheme://user:pass@host` URLs; intake knew `github_pat_…` and Stripe-style `sk_<env>_<key>`.
Everything in this file is the UNION: learning about a new credential shape now lands once.

WHAT SELECTS A RULE SET — AND WHY IT IS NOT THE CALLER. This file used to hold one shared floor and
tell every caller to "keep its own context-sensitive rules". That sentence was the defect. It made
choosing a rule set an unaided judgement call taken once per caller, with nothing checking the
answer — so the autorun drain, arriving third, read it, picked the shared floor for CHILD PROCESS
STDERR, and `password=…`, `Authorization: Basic …` and `Authorization: token …` walked through a door
that had just been built to stop exactly them. A fourth caller (`idc_pr_finish.py`) never asked the
question at all and wrote raw `gh` stderr to a file on disk.

Read the objections that produced the split and they are all objections to ONE THING:

  * The broad "any 40+ character opaque run is a credential we don't have a name for" backstop must
    NOT run over intake text. Intake's review binding note is literally
    `manifest_content_sha256=<64 hex>` and its review filenames embed the same digest, and intake
    REJECTS (hard error) rather than redacts — so that backstop would make every review IDC has ever
    stamped permanently unvalidatable.
  * The broad `…secret…|…token…|…key…= value` rule must NOT run over intake text either: it matches
    on substrings, so `TOKENIZER_MODEL=…` is a "token". Intake replaces it with a name-segment rule
    specifically so that `KEYBOARD_LAYOUT`, `COMPASS_MODE` and `TOKENIZER_MODEL` survive — deliberate
    false-positive controls with tests behind them.
  * The `Basic …` / `token …` arms of the auth-header rule are wrong over prose for the same reason
    ("basic understanding", "token authorization" both match). `Bearer …` is safe enough for prose.
  * Intake's machine-path and private-URL rules must NOT run over live-check output: a live surface is
    a URL, and its verify command's output is expected to name paths. Redacting those would empty the
    evidence record of the only thing it is for.

Every one of those is an objection to **HUMAN-AUTHORED PROSE**, and none is an objection to machine
output — where `TOKENIZER_MODEL=…` losing its value costs a re-run and keeping it costs a rotation.
So the discriminator is not who is holding the text, it is WHERE THE TEXT CAME FROM, and it has
exactly two values. This module publishes both as named profiles:

  * `PROSE_SAFE_SHAPES` (alias `SHAPES`) — the floor that is safe over a document a person wrote.
  * `MACHINE_OUTPUT_SHAPES` — that floor PLUS the auth-verb arms and the named-secret rule, i.e.
    exactly the rules whose only objection was a prose objection.

…and one function, `scrub()`, which is THE door for text a child process produced. A new caller no
longer picks a rule list; it answers one question — *did a human write this, or did a child process
print it?* — and that answer names the function. `tests/smoke/phase11-honesty-repro.sh` R28 walks
every module under `scripts/` and fails if a child's stderr is read anywhere without passing through
that door, so this is a property of the code rather than a convention in a comment.

WHAT STAYS OUT OF BOTH PROFILES, and why that is a derivation rather than a leftover. The live
check's opaque-run backstop is not a rule, it is a GUESS ("we have no name for this, assume the
worst"). A guess is affordable where the text is an unpredictable capture — a project's own verify
probe, whose output nobody can characterise in advance — and unaffordable where the text is a
STRUCTURED DIAGNOSTIC an operator has to act on: in `gh`/`git` stderr every 40-character opaque run
is a commit sha or a node id, which is the identifier the message exists to carry. So it stays where
the guess is affordable, declared in `idc_live_check.py` next to the capture it guards.

The two callers therefore still keep OPPOSITE BIASES — the live check over-redacts (an unreadable
excerpt costs a re-run; a leaked token costs a rotation), intake protects a human-authored document
from being mangled or hard-rejected — but the bias now follows the text, not the author of the call.

QUANTIFIERS. Every pattern here is either bounded or a single linear character class. This is not
tidiness: an unbounded `[\\w.-]*` around a named-secret rule once redacted an entire capture, and a
400 KB single-line output once wedged the gate for minutes with no timeout left to save it. Note that
the open-ended `{16,}` forms are deliberate — an UPPER bound would match only a prefix of an
over-long token and leave its tail in the clear, which is worse than no bound at all.

REACH. A caller that CUTS text before redacting it needs to know how far one match can span, because
a cut destroys the left-hand context every rule here anchors on (`reach` below, and the head
quarantine in `idc_live_check.py` that consumes it). That number is COMPUTED from the patterns rather
than written down beside them, so a rule with a longer bound raises the caller's guard by itself and
a rule with an open-ended one is forced to declare which structural family closes it.

USAGE:
    import idc_credential_shapes as CS
    text = CS.scrub(text)                                    # child-process output — THE door
    for pattern, repl in CS.bake(CS.SHAPES, "[REDACTED]"):   # human prose — substitution
        text = pattern.sub(repl, text)
    if any(p.search(text) for p in CS.PATTERNS):             # human prose — detection
        ...
"""
import re

# The PEM block's two DELIMITERS, defined once and composed into the block rule below, because a
# consumer that has to reason about a block cut in half (the head quarantine) needs to recognize the
# footer on its own — and a second, hand-copied footer pattern is a drift waiting to happen.
PEM_BLOCK_OPEN = re.compile(r"-----BEGIN[^-]*PRIVATE KEY-----")
PEM_BLOCK_CLOSE = re.compile(r"-----END[^-]*PRIVATE KEY-----")

# A PEM private-key block, header to footer. `.*?` is lazy and anchored on both ends, so it cannot run
# away past the matching footer.
PEM_PRIVATE_KEY_BLOCK = (
    re.compile(PEM_BLOCK_OPEN.pattern + r".*?" + PEM_BLOCK_CLOSE.pattern, re.S),
    "{marker}",
)

# `scheme://user:pass@host` — credentials smuggled into a URL. The scheme and the `@` are kept so the
# reader can still tell WHAT was reached; only the userinfo is destroyed.
URL_USERINFO = (
    re.compile(r"(?i)\b([a-z][a-z0-9+.-]{0,32}://)[^/\s:@]{1,256}:[^/\s@]{1,256}@"),
    r"\1{marker}@",
)

# `Authorization: Bearer …`. Only the `Bearer` arm is shared — see the module docstring on why the
# `Basic`/`token` arms stay live-check-only (they match ordinary prose).
#
# THE SEPARATOR IS BOUNDED (`\s{1,64}`, not `\s+`) so this rule has a finite REACH. An unbounded
# separator makes the maximum span of a match infinite, and a consumer that must quarantine the
# region a cut could have corrupted then has nothing to size itself against. The cost is that a
# header with more than 64 whitespace characters between the verb and the token stops matching THIS
# rule — a shape no real capture produces, and one the live check's opaque-run backstop still covers.
BEARER_HEADER = (
    re.compile(r"(?i)\b(bearer)\s{1,64}[A-Za-z0-9._~+/=-]{8,4096}"),
    r"\1 {marker}",
)

# Credential shapes that are recognizable BARE, with no surrounding assignment or header — the union of
# what both callers knew. Each arm is a vendor's documented prefix, so a match is not a heuristic.
KNOWN_CREDENTIAL_SHAPES = (
    re.compile(
        r"\b(?:"
        r"gh[pousr]_[A-Za-z0-9]{16,}"              # GitHub personal/oauth/server/refresh tokens
        r"|github_pat_[A-Za-z0-9_]{20,}"           # GitHub fine-grained PAT
        r"|sk-[A-Za-z0-9_-]{16,}"                  # OpenAI-style (covers sk-proj-…)
        r"|sk_[A-Za-z0-9]+_[A-Za-z0-9_]{20,}"      # Stripe-style sk_<env>_<key>
        r"|xox[baprs]-[A-Za-z0-9-]{10,}"           # Slack
        r"|AKIA[0-9A-Z]{16}"                       # AWS access key id
        r"|AIza[0-9A-Za-z_-]{20,}"                 # Google API key
        r"|ya29\.[0-9A-Za-z_-]{10,}"               # Google OAuth access token
        r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"   # JWT
        r")"),
    "{marker}",
)

# `Authorization: Basic …` / `token …` — the two arms of the auth-header rule that are WRONG over
# human prose ("a basic understanding", "token authorization" both match) and exactly right over
# machine output. Bounded separator for the same REACH reason as `BEARER_HEADER` above.
AUTH_VERB_HEADER = (
    re.compile(r"(?i)\b(basic|token)\s{1,64}[A-Za-z0-9._~+/=-]{8,4096}"), r"\1 {marker}",
)

# Anything that NAMES itself a secret: key/token/secret/password/credential/auth `=` or `:` value.
# Matches on SUBSTRINGS, which is why it is machine-output-only: over prose it eats `TOKENIZER_MODEL=…`
# and intake keeps a name-segment rule instead. Over a child's stderr, eating one of those costs a
# re-run and keeping it costs a rotation — which is the whole trade this module is built on.
NAMED_SECRET_ASSIGNMENT = (
    re.compile(r"(?i)([\w.-]{0,32}(?:secret|password|passwd|token|api[_-]?key|apikey|credential|"
               r"authorization|auth)[\w.-]{0,32})\s{0,64}[:=]\s{0,64}"
               r"(\"[^\"]{0,512}\"|'[^']{0,512}'|\S{1,512})"),
    r"\1={marker}",
)

# ── THE TWO PROFILES ─────────────────────────────────────────────────────────────────────────────
# CANONICAL ORDER in both: the structured, multi-character shapes first, so a PEM block or a URL is
# recognized whole before a narrower rule can chew a piece out of it.

# Safe over a document a HUMAN wrote. `SHAPES` is kept as the name the prose callers already use.
PROSE_SAFE_SHAPES = (PEM_PRIVATE_KEY_BLOCK, URL_USERINFO, BEARER_HEADER, KNOWN_CREDENTIAL_SHAPES)
SHAPES = PROSE_SAFE_SHAPES

# Safe over anything a CHILD PROCESS printed — the prose floor plus the two rules whose only
# objection was a prose objection. See the module docstring for why provenance, not caller identity,
# is what selects between these.
MACHINE_OUTPUT_SHAPES = (PEM_PRIVATE_KEY_BLOCK, URL_USERINFO, BEARER_HEADER,
                         AUTH_VERB_HEADER, NAMED_SECRET_ASSIGNMENT, KNOWN_CREDENTIAL_SHAPES)

# The detection-only view: the same patterns without their replacement templates, for a caller that
# only needs to ask "is there a credential in here?" (intake's reject path) rather than rewrite.
PATTERNS = tuple(pattern for pattern, _ in SHAPES)

# A reviewer reading a receipt should be able to tell "a private key was here" from "an opaque token
# was here", so the PEM block carries its own, more informative marker wherever it is redacted.
PEM_MARKER = "[REDACTED PRIVATE KEY]"
MARKER = "[REDACTED]"


def machine_output_redactors(marker=MARKER, pem_marker=PEM_MARKER):
    """The MACHINE_OUTPUT profile, baked into (pattern, replacement) pairs in canonical order.

    Exposed as well as used by `scrub` because `idc_live_check` appends its own opaque-run backstop to
    this list and then MEASURES the whole list (`reach`) to size its head quarantine — so it needs the
    pairs, not just the substitution. Every consumer that builds a redactor list starts from here, so
    a rule added to the profile reaches all of them without a second edit."""
    return (bake((PEM_PRIVATE_KEY_BLOCK,), pem_marker)
            + bake(MACHINE_OUTPUT_SHAPES[1:], marker))


def bake(entries, marker):
    """Resolve `{marker}` in each entry's replacement template, returning (pattern, replacement) pairs
    ready for `pattern.sub`.

    The templates are parameterized because the two callers label a redaction differently — the live
    check writes `[REDACTED]`, intake writes the category-specific `[REDACTED_CREDENTIAL]` — while the
    PATTERNS themselves must stay identical. A template may carry group backreferences (`\\1`), which is
    why this is a placeholder substitution rather than a plain replacement string."""
    return tuple((pattern, template.replace("{marker}", marker)) for pattern, template in entries)


def contains(text):
    """True iff `text` holds any self-identifying credential shape (detection only, no rewrite)."""
    return any(pattern.search(text or "") for pattern in PATTERNS)


def scrub(text):
    """THE DOOR for text a CHILD PROCESS produced — apply the machine-output profile and return it.

    CALL THIS AT THE READ, not at the message. A program reads a child's `stderr` exactly once and
    then interpolates it into three raises, a diagnostic, a receipt and a board comment; scrubbing at
    the interpolations is per-site bookkeeping that is always one site short (F1 → F20 → F33 → F35 →
    F40, five rounds of the same finding). Scrubbing where the bytes are READ covers every downstream
    use by construction, and there is exactly one read per child, so a census can see them all —
    which is what `tests/smoke/phase11-honesty-repro.sh` R28 does over every module in `scripts/`.

    WHY `stderr` AND NOT `stdout`. In this repo `stdout` is DATA — JSON, a porcelain listing, a
    verdict line — and is parsed by its reader; `stderr` is a MESSAGE and is only ever shown or
    stored. A caller that treats a child's stdout as a message (the autorun drain's verdict line does)
    passes it here too; a caller that parses it must not, or it would be parsing redaction markers.

    Idempotent, so scrubbing twice on a path that crosses two modules costs nothing but a pass."""
    out = text or ""
    if not out:
        return text
    for pattern, repl in machine_output_redactors():
        out = pattern.sub(repl, out)
    return out


# ── REACH ────────────────────────────────────────────────────────────────────────────────────────
_CHAR_CLASS = re.compile(r"\[(?:\\.|[^\]\\])*\]", re.S)
_INLINE_FLAGS = re.compile(r"\(\?[aiLmsux]+\)")
_GROUP_OPEN = re.compile(r"\(\?(?:P<\w+>|P=\w+|[:=!]|<[=!])")
_COUNTED = re.compile(r"\{(\d+)(,(\d*))?\}")


def reach(pattern):
    """The maximum number of characters ONE match of `pattern` can span — or **None when that is
    unbounded**.

    WHY A CONSUMER NEEDS THIS. Every rule in this module is LEFT-ANCHORED: it recognizes a credential
    by the context in front of it (a scheme, a header verb, a label, a BEGIN line). So a caller that
    CUTS text before redacting it — `idc_live_check._drain_bounded` keeps only the last N bytes of a
    chatty probe's output — destroys exactly that context, and no rule here can see what is left. A
    match is contiguous, so the surviving remnant of a match that straddled the cut is always a PREFIX
    of the retained text, never a floating interior region. That prefix is what the caller has to
    quarantine, and its length is bounded by the longest match any rule can produce: this number.

    COMPUTED, NOT DECLARED, and that is the whole point. Writing the number down beside the table
    would be one more thing to forget when a rule changes — which is the drift this module was created
    to end. Because it is derived, a rule with a longer bound raises every consumer's guard by itself.

    DELIBERATELY CONSERVATIVE. Alternation is SUMMED rather than maxed and a zero-width escape (`\\b`)
    counts as one character, so the answer is an over-estimate. Over-estimating makes a consumer's
    quarantine bigger, which costs readable evidence; under-estimating would leak a credential. The
    asymmetry decides the bias.

    FAIL-CLOSED ON ANYTHING IT CANNOT MEASURE. An open-ended quantifier (`*`, `+`, `{m,}`), a
    quantifier applied to a GROUP (whose span this linear walk does not track), or an exotic construct
    returns None rather than a number a caller would trust. None does not mean "no bound is needed" —
    it means the rule cannot be closed by a byte quarantine and must be handled by its STRUCTURE
    instead (a delimited block by its delimiters, a bare token run by its whitespace boundary). The
    live check refuses to load if any rule it applies is unbounded and not registered as one of those.
    """
    src = pattern.pattern if hasattr(pattern, "pattern") else pattern
    total, i, n = 0, 0, len(src)
    while i < n:
        ch = src[i]
        if ch == "(":                                  # group syntax carries no characters itself
            if src.startswith("(?", i):
                m = _INLINE_FLAGS.match(src, i) or _GROUP_OPEN.match(src, i)
                if not m:
                    return None                        # an exotic construct — do not guess
                i = m.end()
            else:
                i += 1
            continue
        if ch == ")":
            i += 1
            if i < n and src[i] in "*+?{":
                return None                            # a quantified GROUP — this walk cannot size it
            continue
        if ch == "|":                                  # alternation summed, not maxed (over-estimate)
            i += 1
            continue
        if ch == "\\":                                 # one escaped atom (`\b` is zero-width: +1)
            i += 2
        elif ch == "[":
            m = _CHAR_CLASS.match(src, i)
            if not m:
                return None
            i = m.end()
        else:
            i += 1
        span = 1                                       # …and the quantifier that applies to it
        if i < n:
            if src[i] in "*+":
                return None
            if src[i] == "?":
                i += 1
            elif src[i] == "{":
                m = _COUNTED.match(src, i)
                if not m:
                    return None
                if m.group(2) and m.group(3) == "":
                    return None                        # `{m,}` — open-ended on purpose, see above
                span = int(m.group(3) or m.group(1))
                i = m.end()
            if i < n and src[i] == "?":                # a lazy quantifier spans the same maximum
                i += 1
        total += span
    return total
