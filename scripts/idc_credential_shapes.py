"""idc_credential_shapes.py — the ONE table of self-identifying credential shapes.

WHY THIS EXISTS. Two IDC surfaces scrub credentials out of text before it is written down:
`idc_live_check.py` (a verify command's captured output, on its way into a committed evidence record)
and `idc_intake_manifest.py` (human prose lifted out of an external document, on its way into a
manifest). They were written independently and had DRIFTED IN BOTH DIRECTIONS — each caught real
credential shapes the other missed, so which secrets got redacted depended on which door the text
happened to walk through. The live check knew Google API keys, Google OAuth tokens, JWTs, PEM private
keys and `scheme://user:pass@host` URLs; intake knew `github_pat_…` and Stripe-style `sk_<env>_<key>`.
Everything in this file is the UNION: learning about a new credential shape now lands once.

WHAT BELONGS HERE — AND WHAT DELIBERATELY DOES NOT. This module holds only shapes that are
SELF-IDENTIFYING: a run of text that is a credential no matter what surrounds it, in prose or in
machine output. That is what makes them safe to apply everywhere. Each caller keeps its own
CONTEXT-SENSITIVE rules, and that split is a finding, not an oversight — cross-applying them was tried
and each direction breaks something real:

  * The live check's broad "any 40+ character opaque run is a credential we don't have a name for"
    backstop must NOT run over intake text. Intake's review binding note is literally
    `manifest_content_sha256=<64 hex>` and its review filenames embed the same digest, and intake
    REJECTS (hard error) rather than redacts — so that backstop would make every review IDC has ever
    stamped permanently unvalidatable.
  * The live check's broad `…secret…|…token…|…key…= value` rule must NOT run over intake text either:
    it matches on substrings, so `TOKENIZER_MODEL=…` is a "token". Intake replaces it with a
    name-segment rule specifically so that `KEYBOARD_LAYOUT`, `COMPASS_MODE` and `TOKENIZER_MODEL`
    survive — deliberate false-positive controls with tests behind them.
  * Intake's machine-path and private-URL rules must NOT run over live-check output: a live surface is
    a URL, and its verify command's output is expected to name paths. Redacting those would empty the
    evidence record of the only thing it is for.
  * The `Basic …` / `token …` arms of the live check's auth-header rule stay live-only for the same
    prose reason ("basic understanding", "token authorization" both match). `Bearer …` is safe enough
    for prose to be shared.

So the two callers keep OPPOSITE BIASES on purpose — the live check over-redacts (an unreadable
excerpt costs a re-run; a leaked token costs a rotation), intake protects a human-authored document
from being mangled or hard-rejected — and this module is the floor they agree on.

QUANTIFIERS. Every pattern here is either bounded or a single linear character class. This is not
tidiness: an unbounded `[\\w.-]*` around a named-secret rule once redacted an entire capture, and a
400 KB single-line output once wedged the gate for minutes with no timeout left to save it. Note that
the open-ended `{16,}` forms are deliberate — an UPPER bound would match only a prefix of an
over-long token and leave its tail in the clear, which is worse than no bound at all.

USAGE:
    import idc_credential_shapes as CS
    for pattern, repl in CS.bake(CS.SHAPES, "[REDACTED]"):   # substitution
        text = pattern.sub(repl, text)
    if any(p.search(text) for p in CS.PATTERNS):             # detection
        ...
"""
import re

# A PEM private-key block, header to footer. `.*?` is lazy and anchored on both ends, so it cannot run
# away past the matching footer.
PEM_PRIVATE_KEY_BLOCK = (
    re.compile(r"-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----", re.S),
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
BEARER_HEADER = (
    re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,4096}"),
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

# CANONICAL ORDER: the structured, multi-character shapes first, so a PEM block or a URL is recognized
# whole before a narrower rule can chew a piece out of it.
SHAPES = (PEM_PRIVATE_KEY_BLOCK, URL_USERINFO, BEARER_HEADER, KNOWN_CREDENTIAL_SHAPES)

# The detection-only view: the same patterns without their replacement templates, for a caller that
# only needs to ask "is there a credential in here?" (intake's reject path) rather than rewrite.
PATTERNS = tuple(pattern for pattern, _ in SHAPES)


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
