#!/bin/sh
# Quiet runtime preflight shared by hook wrappers. IDC helpers use Python 3.10 syntax.
command -v python3 >/dev/null 2>&1 || exit 1
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
  >/dev/null 2>&1
