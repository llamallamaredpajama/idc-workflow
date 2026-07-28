#!/bin/sh
# IDC Path Gate pre-push backstop wrapper.
set -u
ROOT="${1:-}"
[ -n "$ROOT" ] || { echo "IDC Path Gate pre-push: plugin root missing" >&2; exit 1; }
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0
REMOTE="${2:-}"
[ -n "$REMOTE" ] || { echo "IDC Path Gate pre-push: actual push remote missing" >&2; exit 1; }
sh "$ROOT/scripts/idc_python_runtime.sh" || {
  echo "IDC Path Gate pre-push requires Python 3.10 or newer." >&2
  exit 1
}
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exec python3 "$ROOT/scripts/idc_git_path_gate.py" pre-push \
  --repo "$REPO" --plugin-root "$ROOT" --remote "$REMOTE"
