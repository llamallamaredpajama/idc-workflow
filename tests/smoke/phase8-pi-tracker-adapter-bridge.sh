#!/bin/bash
# idc-assert-class: doc
# Phase 8 smoke — Pi roles must not confuse IDC skills with coms-net peers.
#
# Live Pi e2e exposed build-finish trying to `coms_net_send` to `idc:idc-tracker-adapter`.
# The hub correctly blocked that unknown target, but the issue stayed In-Progress. A first-class
# Pi runtime must teach roles that `idc:*` names are local procedures/skills, never peer targets,
# and that tracker close is executed via the backend recipe (Status=Done + issue close), not by
# messaging a non-existent adapter peer.
#
# Usage: bash tests/smoke/phase8-pi-tracker-adapter-bridge.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
A="$PLUGIN/runtime/pi/.pi/agents/idc"
fails=0

have_file() {
  local f="$1" re="$2" label="$3"
  if ! grep -qiE "$re" "$A/$f"; then
    echo "MISSING in $f: $label (/$re/)"
    fails=$((fails+1))
  fi
}

absent_file() {
  local f="$1" re="$2" label="$3"
  if grep -qiE "$re" "$A/$f"; then
    echo "FORBIDDEN in $f: $label (/$re/)"
    fails=$((fails+1))
  fi
}

# All build roles mention the tracker adapter, so all build roles need the Pi-specific warning.
for f in build-implementer.md build-reviewer.md build-finisher.md; do
  have_file "$f" 'idc:\*|idc:[a-z-]+[^.]{0,120}(not|never)[^.]{0,80}(coms-net|coms_net)[^.]{0,80}(peer|target)' 'IDC skill names are not coms-net targets'
  have_file "$f" 'Never[^.]{0,120}coms_net_send[^.]{0,120}idc:' 'explicitly forbids coms_net_send to idc:* skills'
  absent_file "$f" "target[[:space:]]*:[[:space:]]*['\"]?idc:idc-tracker-adapter|coms_net_send[^\\n]{0,80}['\"]?idc:idc-tracker-adapter" 'no example tells a role to send to idc:idc-tracker-adapter'
done

# The finisher owns closeout, so it must include enough backend recipe shape to close without a peer.
have_file build-finisher.md 'close\(issue\)|tracker close|close issue' 'names the close operation'
have_file build-finisher.md 'Status[ =:→-]*Done|Done[^.]{0,80}gh issue close|setField[^.]{0,80}Status[^.]{0,80}Done' 'close sets Status=Done before/with issue close'
have_file build-finisher.md 'gh issue close' 'close uses gh issue close on the github backend'
have_file build-finisher.md '(missing|empty|unresolved)[^.]{0,100}(item|field|option|project)[^.]{0,120}(fail-closed|blocked-stop|do NOT mutate|do not mutate)' 'blank tracker ids fail closed instead of silently skipping Done'

if [ "$fails" -eq 0 ]; then
  echo "PASS: Pi tracker-adapter bridge is explicit — idc:* skills are not coms-net peers, and build-finish closes via the backend recipe fail-closed"
  exit 0
fi
echo "FAIL: $fails Pi tracker-adapter bridge invariant(s) unmet"
exit 1
