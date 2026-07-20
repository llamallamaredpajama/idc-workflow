#!/bin/bash
# idc-assert-class: behavior
# credential-scrubber-parity.sh — governance scenario: IDC's two credential scrubbers agree.
#
# THE DEFECT THIS CLOSES. Two shipped surfaces scrub credentials out of text before writing it down:
#   * scripts/idc_live_check.py  — a verify command's captured output, on its way into a COMMITTED
#     evidence record (and onto stderr);
#   * scripts/idc_intake_manifest.py — human prose lifted out of an external document, on its way into
#     an intake manifest.
# They were written independently and had DRIFTED IN BOTH DIRECTIONS, so which secrets got redacted
# depended on which door the text walked through. Concretely, before the shared table:
#   * the live check knew Google API keys (AIza…), Google OAuth tokens (ya29.…), JWTs, PEM private-key
#     blocks and `scheme://user:pass@host` — and intake did NOT, so all five rode through intake
#     UNREDACTED into a committed manifest;
#   * intake knew `github_pat_…` and Stripe-style `sk_<env>_<key>` — which the live check caught only
#     incidentally, via its length backstop.
# Both now consume scripts/idc_credential_shapes.py. THIS SUITE IS THE PARITY ASSERTION: every shape
# either side ever caught must be caught by BOTH.
#
# WHY THE TABLE IS NOT SIMPLY "THE UNION OF EVERYTHING BOTH FILES HAD". Only SELF-IDENTIFYING shapes
# are shared. Two of the live check's rules are deliberately NOT applied to intake, and section C
# proves that exclusion is load-bearing rather than an oversight:
#   * its "any 40+ character opaque run is a credential" backstop — intake's review binding note IS
#     `manifest_content_sha256=<64 hex>`, and intake REJECTS rather than redacts, so that rule would
#     make every stamped review permanently unvalidatable;
#   * its `…token…=value` substring rule — it matches `TOKENIZER_MODEL=…`, which intake's name-segment
#     logic exists specifically to let through.
#
# RED-WHEN-BROKEN (each mutation made in the REAL source, observed red, restored):
#   * delete any one arm of KNOWN_CREDENTIAL_SHAPES (e.g. `AIza`, `ya29\.`, `github_pat_`) ⇒ A RED for
#     that shape, on BOTH consumers;
#   * drop CS.PATTERNS from idc_intake_manifest's credential tuple ⇒ every A intake assertion RED;
#   * drop the shared entries from idc_live_check's _REDACTORS ⇒ the live assertions RED (the length
#     backstop still masks some, which is exactly why A asserts per-shape and not merely "REDACTED");
#   * add the opaque-run backstop or the broad named-secret rule to intake's tuple ⇒ C RED;
#   * make idc_intake_manifest's shared-table import fall back to a narrower rule set instead of
#     failing closed ⇒ D RED.
#
# Hermetic: pure in-process calls, no repo, no git, no GitHub.
# Usage: bash tests/smoke/governance/credential-scrubber-parity.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

SCRIPTS="$GOV_PLUGIN/scripts"
[ -f "$SCRIPTS/idc_credential_shapes.py" ] \
  || gov_fail "scripts/idc_credential_shapes.py (the shared credential table) not found"

python3 - "$SCRIPTS" <<'PY' || gov_fail "credential scrubber parity failed (see the assertions above)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_live_check as LIVE
import idc_intake_manifest as INTAKE

failures = []

# ════════════════════════════════════════════════════════════════════════════════════════════════
# A. PARITY — every shape EITHER scrubber ever caught must now be caught by BOTH.
#
# Each case names the secret substring that must NOT survive. The assertion is per-shape and on the
# SECRET ITSELF, never merely "the word REDACTED appears": the live check has a broad length backstop
# that would mask a deleted rule and turn this suite green against a real regression.
# ════════════════════════════════════════════════════════════════════════════════════════════════
CASES = [
    # (label, text containing the secret, the substring that must be destroyed, which side had it first)
    ("pem-private-key",
     "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKsecretkeymaterial\n-----END RSA PRIVATE KEY-----",
     "MIIBOgIBAAJBAKsecretkeymaterial", "live-check only"),
    ("url-userinfo", "cloning https://alice:hunter2@git.example.test/x", "hunter2", "live-check only"),
    ("bearer-header", "Authorization: Bearer ghp_ABCDEFGHIJKLMNOP012345",
     "ghp_ABCDEFGHIJKLMNOP012345", "both"),
    ("github-classic", "token=ghp_ABCDEFGHIJKLMNOP012345", "ghp_ABCDEFGHIJKLMNOP012345", "both"),
    ("github-fine-grained", "use github_pat_11ABCDEFG0abcdefghijklmnop here",
     "github_pat_11ABCDEFG0abcdefghijklmnop", "intake only"),
    ("openai", "key sk-abcdefghijklmnop012345 rotated", "sk-abcdefghijklmnop012345", "both"),
    ("openai-proj", "key sk-proj-abcdefghijklmnop012345 rotated",
     "sk-proj-abcdefghijklmnop012345", "both"),
    ("stripe-style", "live sk_test_sample_sensitive_value_1234567890 here",
     "sk_test_sample_sensitive_value_1234567890", "intake only"),
    ("slack", "hook xoxb-1234567890-abcdefghij posted", "xoxb-1234567890-abcdefghij", "both"),
    ("aws-access-key-id", "id AKIAIOSFODNN7EXAMPLE used", "AKIAIOSFODNN7EXAMPLE", "both"),
    ("google-api-key", "gmaps AIzaSyA0123456789abcdefghijklmnopqrs live",
     "AIzaSyA0123456789abcdefghijklmnopqrs", "live-check only"),
    ("google-oauth", "access ya29.a0AfH6SMBabcdefghij granted", "ya29.a0AfH6SMBabcdefghij",
     "live-check only"),
    ("jwt", "cookie eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N set",
     "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", "live-check only"),
]

for label, text, secret, provenance in CASES:
    live_out = LIVE.redact(text)
    if secret in live_out:
        failures.append(f"A[{label}] idc_live_check.redact LEAKED the secret (was: {provenance})")
    intake_out, categories = INTAKE._redact_human_text(text)
    if secret in intake_out:
        failures.append(f"A[{label}] idc_intake_manifest LEAKED the secret (was: {provenance})")
    if "credential" not in categories:
        failures.append(
            f"A[{label}] idc_intake_manifest did not CLASSIFY it as a credential (got {categories}) — "
            "the category drives the hard-reject path, so a redaction without it is only half the gate")

# The reject path is what a manifest/review actually hits; prove it fires, not just the redactor.
for label, text, secret, _prov in CASES:
    try:
        INTAKE._reject_unsafe_text(text, "review.notes[0]")
    except INTAKE.IntakeError as e:
        if secret in str(e):
            failures.append(f"A[{label}] the rejection message ECHOED the secret")
    else:
        failures.append(f"A[{label}] _reject_unsafe_text ACCEPTED text containing a live credential")

# ════════════════════════════════════════════════════════════════════════════════════════════════
# B. The shared table is genuinely SHARED — not two copies that happen to agree today.
# ════════════════════════════════════════════════════════════════════════════════════════════════
import idc_credential_shapes as CS
shared = set(CS.PATTERNS)
if not shared:
    failures.append("B the shared table is EMPTY")
if not shared <= set(INTAKE._sensitive_text_patterns()["credential"]):
    failures.append("B idc_intake_manifest's credential patterns are not a superset of the shared "
                    "table — it has stopped consuming it, so the two can drift again")
live_patterns = {p for p, _ in LIVE._REDACTORS}
if not shared <= live_patterns:
    failures.append("B idc_live_check's _REDACTORS no longer contains every shared pattern — it has "
                    "stopped consuming the table, so the two can drift again")

# ════════════════════════════════════════════════════════════════════════════════════════════════
# C. THE EXCLUSIONS ARE LOAD-BEARING — intake must NOT inherit the live check's broad rules.
#
# These are not "nice to keep working": the first two are structural to intake's own format, and the
# rest are documented false-positive controls with their own round-7/8 coverage. If a future change
# imports the live check's whole rule set into intake "for consistency", every one of these breaks.
# ════════════════════════════════════════════════════════════════════════════════════════════════
MUST_SURVIVE = [
    ("review-binding-note", "manifest_content_sha256=" + "a" * 64,
     "intake's review binding note IS a 64-char hex digest — the opaque-run backstop would make every "
     "stamped review unvalidatable"),
    ("review-basename", "2026-07-19-example.review." + "b" * 64 + ".json",
     "the stamped review filename embeds the same digest"),
    ("tokenizer-control", "TOKENIZER_MODEL=test-model",
     "matches the live check's `…token…=value` substring rule; intake's name-segment logic exists to "
     "let it through"),
    ("keyboard-control", "KEYBOARD_LAYOUT=us-test-layout", "substring-of-a-secret-word control"),
    ("compass-control", "COMPASS_MODE=north", "substring-of-a-secret-word control"),
    ("region-control", "SERVICE_REGION=us-test-1", "documented non-secret neighbour of a real secret"),
    ("port-control", "SSH_PORT=22", "documented non-secret neighbour of a real secret"),
    ("long-harmless-identifier", "H" * 16000,
     "round-9 performance + false-positive fixture — a long opaque run is not a credential here"),
]
for label, text, why in MUST_SURVIVE:
    redacted, categories = INTAKE._redact_human_text(text)
    if redacted != text or categories:
        failures.append(f"C[{label}] intake redacted text it must leave alone ({why}); "
                        f"categories={categories}")

# The same strings are the ones the live check is EXPECTED to chew on — asserting that keeps the
# asymmetry deliberate rather than accidental.
if LIVE.redact("manifest_content_sha256=" + "a" * 64) == "manifest_content_sha256=" + "a" * 64:
    failures.append("C the live check's opaque-run backstop has been LOST — it, not intake, is the "
                    "surface whose bias is deliberate over-redaction")

# ════════════════════════════════════════════════════════════════════════════════════════════════
# D. A scrubber that cannot load its table must FAIL CLOSED, never scrub less.
#
# idc_intake_manifest is an import-graph root on purpose (a lone copy must still run — see
# phase1-pipe-safety.sh section F), so the shared-table import is tolerant. Tolerant must not mean
# "silently redact less": the only safe response to a missing credential table is to refuse the scan.
# ════════════════════════════════════════════════════════════════════════════════════════════════
saved = INTAKE.CS
INTAKE.CS = None
try:
    INTAKE._redact_human_text("ghp_ABCDEFGHIJKLMNOP012345")
except INTAKE.IntakeError:
    pass   # correct: refused
except Exception as e:  # noqa: BLE001
    failures.append(f"D a missing credential table raised {type(e).__name__}, not a clean IntakeError")
else:
    failures.append("D SILENT DOWNGRADE: with the shared table unavailable, intake scrubbed anyway "
                    "instead of refusing — a relocated copy would under-redact and say nothing")
finally:
    INTAKE.CS = saved

if failures:
    for f in failures:
        print("  RED: " + f)
    raise SystemExit(1)
print("  ok A: all 13 credential shapes either scrubber ever caught are now caught by BOTH "
      "(redacted, classified, and rejected)")
print("  ok B: both consumers genuinely read the shared table (not two copies that agree today)")
print("  ok C: intake does NOT inherit the live check's broad rules — its binding note, review "
      "filename and 6 false-positive controls all survive")
print("  ok D: a scrubber that cannot load its table refuses the scan instead of scrubbing less")
PY

echo "PASS: IDC's two credential scrubbers share one table — full parity on every known credential shape, with the deliberately unshared broad rules staying unshared and a missing table failing closed"
