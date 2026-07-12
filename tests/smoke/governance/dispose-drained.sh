#!/bin/bash
# dispose-drained.sh — governance scenario: the `drained` terminal disposition (#150 door unification).
#
# A drained Recirculation-inbox ticket is a NON-verdict terminal disposition: it has no review
# verdict, so the verdict-guarded `close` cannot close it, and before #150 the operator retired it
# through a RAW tracker close that bypassed the engine + journal. The new guarded op
# `dispose --disposition drained` mints Done ONLY when the `recirc-provenance` guard passes: the item
# sits on Stage=Recirculation, is NOT gate-parked (Status != Blocked), AND carries a recirc-provenance
# marker — `idc-recirc-source` (filer) OR `idc-discovery` / `idc-deferral` (a finisher-posted,
# sweep-restaged rogue).
#
# Red-when-broken (the mutation proof): neuter check_drained (return without raising / drop a conjunct)
# → a non-recirc item, a marker-less Recirculation item, OR a Blocked gate-parked ticket closes to
# Done → this FAILs.
#
# Usage: bash tests/smoke/governance/dispose-drained.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

SRC_MARKER='<!-- idc-recirc-source: {"origin":9,"what":"x","key":"k-drain-1"} -->'
SWEEP_MARKER='<!-- idc-recirc-source: {"origin":9,"what":"swept scope"} -->'   # the sweep emits no key
DISC_MARKER='<!-- idc-discovery: {"what":"a swept rogue"} -->'

# ── 1. HAPPY PATH: a Recirculation ticket carrying the idc-recirc-source marker drains to Done ──────
n="$(gov_seed_item "$T" --title 'recirc(nit): drainable' --stage Recirculation --status Todo --comment "$SRC_MARKER")" \
  || fail "could not seed the Recirculation inbox ticket"
eng dispose --disposition drained --num "$n" >/dev/null 2>&1 \
  || fail "dispose --disposition drained refused a valid recirc ticket (Stage=Recirculation + idc-recirc-source marker)"
[ "$(gov_field "$T" "$n" Status)" = "Done" ] || fail "drained disposition did not drive the ticket to Done"
# The close JOURNALS which door + disposition + the VALIDATED evidence (not merely caller args) —
# a drained disposal carries no CLI args, so a record must still carry disposition + the marker key.
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
grep -q '"disposition": *"drained"' "$JOURNAL" || fail "drained close did not journal its disposition"
grep -q '"evidence"' "$JOURNAL"                || fail "drained close did not journal the guard-validated evidence (which door + disposition + evidence)"
grep -q 'k-drain-1' "$JOURNAL"                  || fail "drained close did not journal the recirc-source key it verified as evidence"
echo "  ok (1) a Recirculation ticket with an idc-recirc-source marker drains to Done + journals the disposition & evidence"

# ── 1b. HAPPY PATH: a sweep-restaged rogue (idc-discovery provenance, no idc-recirc-source) drains ──
# idc_recirc_sweep re-stages a discovery/deferral-marked rogue Buildable to Recirculation WITHOUT
# stamping idc-recirc-source; the drain must still reach it or it never fixpoints.
s="$(gov_seed_item "$T" --title 'recirc: swept rogue' --stage Recirculation --status Todo --comment "$DISC_MARKER")" \
  || fail "could not seed the sweep-restaged rogue"
eng dispose --disposition drained --num "$s" >/dev/null 2>&1 \
  || fail "dispose --disposition drained refused a sweep-restaged rogue carrying idc-discovery provenance (drain would never fixpoint)"
[ "$(gov_field "$T" "$s" Status)" = "Done" ] || fail "drained disposition did not drive the swept rogue to Done"
echo "  ok (1b) a sweep-restaged rogue (idc-discovery provenance) drains to Done"

# ── 1c. HAPPY PATH: a sweep-FILED idc-recirc-source ticket (has `what`, NO key) drains ──────────────
# idc_recirc_sweep.recirc_ticket_body emits {origin, what} with no dedupe key (only the filer adds
# one). Requiring `key` would reject every sweep-filed ticket and stall the drain — require `what`.
sw="$(gov_seed_item "$T" --title 'recirc: sweep-filed discovery' --stage Recirculation --status Todo --comment "$SWEEP_MARKER")" \
  || fail "could not seed the sweep-filed recirc ticket"
eng dispose --disposition drained --num "$sw" >/dev/null 2>&1 \
  || fail "dispose --disposition drained refused a sweep-filed idc-recirc-source ticket (no key, has what) — the drain would stall"
[ "$(gov_field "$T" "$sw" Status)" = "Done" ] || fail "drained disposition did not drive the sweep-filed ticket to Done"
echo "  ok (1c) a sweep-filed idc-recirc-source ticket (no key, non-empty what) drains to Done"

# ── 2. DENY: a Recirculation ticket with NO provenance marker is refused (not a real recirc ticket) ─
m="$(gov_seed_item "$T" --title 'stray Recirculation item' --stage Recirculation --status Todo)" \
  || fail "could not seed the marker-less Recirculation item"
if eng dispose --disposition drained --num "$m" 2>/dev/null; then
  fail "drained closed a Recirculation item that carries NO recirc-provenance marker (guard bypassed)"
fi
[ "$(gov_field "$T" "$m" Status)" != "Done" ] || fail "denied drained still drove the marker-less item to Done"
echo "  ok (2) a Recirculation item with no recirc-provenance marker is REFUSED (no verdict-free Done)"

# ── 3. DENY: a marker-carrying item that is NOT on Stage=Recirculation is refused (stage conjunct) ──
b="$(gov_seed_item "$T" --title 'buildable with a stray marker' --stage Buildable --status Todo --comment "$SRC_MARKER")" \
  || fail "could not seed the Buildable item with a stray marker"
if eng dispose --disposition drained --num "$b" 2>/dev/null; then
  fail "drained closed a Stage=Buildable item (drain must be confined to the Recirculation inbox)"
fi
[ "$(gov_field "$T" "$b" Status)" != "Done" ] || fail "denied drained still drove the Buildable item to Done"
echo "  ok (3) a marker-carrying item off Stage=Recirculation is REFUSED (drain is inbox-confined)"

# ── 4. DENY: a Blocked (gate-parked) recirc ticket is refused (never discard pending gated work) ────
# A requirements-changing recirc ticket parked behind a human gate rides Stage=Recirculation +
# Status=Blocked and keeps its provenance marker; draining it would discard the work before its
# Think PR merges.
k="$(gov_seed_item "$T" --title 'recirc: parked behind a gate' --stage Recirculation --status Blocked --comment "$SRC_MARKER")" \
  || fail "could not seed the gate-parked recirc ticket"
if eng dispose --disposition drained --num "$k" 2>/dev/null; then
  fail "drained closed a Blocked (gate-parked) recirc ticket — this discards pending work + bypasses the human gate"
fi
[ "$(gov_field "$T" "$k" Status)" != "Done" ] || fail "denied drained still drove the gate-parked ticket to Done"
echo "  ok (4) a Blocked (gate-parked) recirc ticket is REFUSED (pending gated work is never discarded)"

# ── 5. DENY: an EMPTY {} provenance marker is not provenance (a forged verdict-free bypass) ─────────
# Stage moves + comments are both writable through the normal adapter, so a presence-only marker
# check would let an ordinary item be forged into the no-verdict drained door.
e="$(gov_seed_item "$T" --title 'recirc: forged empty marker' --stage Recirculation --status Todo --comment '<!-- idc-recirc-source: {} -->')" \
  || fail "could not seed the empty-marker item"
if eng dispose --disposition drained --num "$e" 2>/dev/null; then
  fail "drained closed a ticket whose idc-recirc-source marker is an empty {} (forged verdict-free bypass)"
fi
[ "$(gov_field "$T" "$e" Status)" != "Done" ] || fail "denied drained still drove the empty-marker item to Done"
echo "  ok (5) an empty {} recirc-source marker is REFUSED (the payload must carry a non-empty key)"

echo "PASS: dispose --disposition drained mints Done ONLY for a Stage=Recirculation, non-Blocked item carrying a VALID recirc-provenance marker (idc-recirc-source/idc-discovery/idc-deferral with a non-empty what — filer key optional) + journals the disposition & evidence; a marker-less item, an empty-{} marker, an off-stage item, and a gate-parked Blocked ticket are all fail-closed"
