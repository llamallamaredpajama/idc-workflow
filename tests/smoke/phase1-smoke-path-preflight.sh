#!/bin/bash
# idc-assert-class: behavior
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORIGINAL="/usr/bin:/bin"
PATH="$ORIGINAL"
. "$HERE/smoke-path-preflight.sh" || exit 1
case ":$PATH:" in *":$ORIGINAL:"*) ;; *) echo "FAIL: original PATH was replaced"; exit 1 ;; esac
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
  [ ! -d "$d" ] || case ":$PATH:" in *":$d:"*) ;; *) echo "FAIL: existing tool dir missing: $d"; exit 1 ;; esac
done
echo "PASS: smoke PATH preflight preserves PATH and prepends existing local tool directories"
