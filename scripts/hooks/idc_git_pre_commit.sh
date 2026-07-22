#!/bin/sh
# IDC Path Gate pre-commit backstop wrapper.
set -u
ROOT="${1:-}"
[ -n "$ROOT" ] || { echo "IDC Path Gate pre-commit: plugin root missing" >&2; exit 1; }
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0
sh "$ROOT/scripts/idc_python_runtime.sh" || {
  echo "IDC Path Gate pre-commit requires Python 3.10 or newer." >&2
  exit 1
}
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec python3 "$ROOT/scripts/idc_git_path_gate.py" pre-commit --repo "$REPO" --plugin-root "$ROOT"
