#!/bin/bash
# fake-pi.sh — a stand-in resident for the fleet-secret smoke (PI_IDC_RESIDENT_BIN seam).
#
# It does NOT run a pi agent. It records the secrets the supervisor put in THIS child's environ so
# the test can prove the distribution property: each resident receives ONLY its own role cap, and
# the master key K is NOT leaked to any resident. Writes under $HOME (the one env var that survives
# the launcher's `env -i`), so the test reads them back from its isolated HOME.
set -uo pipefail

role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) role="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$role" ] || role="unknown"

out="${HOME}/fleet-out"
mkdir -p "$out"
printf '%s\n' "${PI_COMS_NET_ROLE_CAP:-NONE}"      > "$out/$role.cap"
printf '%s\n' "${PI_COMS_NET_ROLE_HMAC_KEY:-NONE}" > "$out/$role.k"
printf '%s\n' "${PI_COMS_NET_AUTH_TOKEN:-NONE}"    > "$out/$role.tok"

# Stay alive briefly so the supervisor's `wait` doesn't race the test's teardown.
sleep 5
