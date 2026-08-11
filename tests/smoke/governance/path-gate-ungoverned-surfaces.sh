#!/bin/bash
# path-gate-ungoverned-surfaces.sh — IDC guards APPLICATION CODE, not the operator's desk.
#
# The defect this lane pins: the shared Path Gate asked only "is this path inside the repository?",
# so in a `controlled` repo EVERY file — `.vscode/settings.json`, `.gitignore`, and `README.md` —
# was refused exactly like `src/app.py` unless a board item had been claimed first. Ordinary editor,
# repository-metadata, and documentation work was impossible without ceremony.
#
# What is asserted here, against ONE fixture with NO live authorization:
#   A. CONTROL — the gate genuinely enforces (application code IS denied). Without this a gate that
#      denied nothing would make every "allowed" probe below vacuously green.
#   B. Low-risk desk surfaces are admitted: project docs, editor preferences, harmless repository
#      metadata.
#   C. The deliberate exclusions still deny: the governance anchor (a hand edit would silently
#      ungovern the repository), machine-owned state under the `*.md` rule (`TRACKER.md`), executable
#      automation, credential-capable config, dependency/build manifests, case variants, nested
#      wildcard lookalikes, a MIXED request that carries application code, and the whole-repository
#      target.
#   D. The git commit AND push doors inherit the same answer: a low-risk desk-only history is
#      admitted, while mixed and application histories are refused.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PATH_GATE="$GOV_PLUGIN/scripts/idc_path_gate.py"
GIT_GATE="$GOV_PLUGIN/scripts/idc_git_path_gate.py"
[ -f "$PATH_GATE" ] || gov_fail "idc_path_gate.py not found at $PATH_GATE"
[ -f "$GIT_GATE" ] || gov_fail "idc_git_path_gate.py not found at $GIT_GATE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; REMOTE="$WORK/remote.git"
mkdir -p "$REPO/docs/workflow" "$REPO/src" "$REPO/.vscode" "$REPO/.idea"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
  git config user.email idc@example.test
  git config user.name 'IDC Ungoverned Surfaces'
)
git init --bare -q "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
# A GOVERNED, ENFORCING repository with NO authorization minted — the exact state an operator sits in
# when they open a repo to change a setting.
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'print("app")\n' > "$REPO/src/app.py"
git -C "$REPO" add .
git -C "$REPO" commit -qm 'test: seed ungoverned-surface fixture' >/dev/null
git -C "$REPO" push -u origin main >/dev/null 2>&1

# `evaluate` exits 0 on allow, 2 on deny — assert the exit status, not scraped prose.
probe() { # probe <expect: allow|deny> <json-path-array> <label>
  local expect="$1" paths="$2" label="$3" rc
  printf '{"action":"edit","paths":%s}' "$paths" \
    | python3 "$PATH_GATE" evaluate --repo "$REPO" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = "allow" ] && [ "$rc" -ne 0 ]; then
    gov_fail "$label should be ungoverned (no claim needed) but the gate denied it (rc=$rc)"
  fi
  if [ "$expect" = "deny" ] && [ "$rc" -eq 0 ]; then
    gov_fail "$label must stay gated but the gate allowed it"
  fi
}

# ── A. CONTROL: the gate is genuinely enforcing in this fixture ───────────────────────────────────
probe deny '["src/app.py"]' "CONTROL: application code with no authorization"

# ── B. the operator's desk is admitted ────────────────────────────────────────────────────────────
probe allow '[".vscode/settings.json"]'        "editor settings (.vscode/)"
probe allow '[".idea/workspace.xml"]'           "editor settings (.idea/)"
probe allow '["README.md"]'                    "root prose (README.md)"
probe allow '["docs/adr/0001-choice.md"]'      "project documentation (docs/)"
probe allow '["CHANGELOG.md"]'                 "root prose (CHANGELOG.md)"
probe allow '["LICENSE"]'                      "the repository license"
probe allow '[".gitignore"]'                   "repository plumbing (.gitignore)"
probe allow '[".gitattributes"]'               "repository plumbing (.gitattributes)"
probe allow '[".editorconfig"]'                "repository plumbing (.editorconfig)"
probe allow '[".dockerignore"]'                "repository plumbing (.dockerignore)"
probe allow '[".vscode/settings.json","README.md",".gitignore"]' "several ungoverned paths at once"

# ── C. the deliberate exclusions still deny ───────────────────────────────────────────────────────
# The anchor is what ARMS every IDC gate; freeing it would make "this repo is governed" hand-editable.
probe deny '["docs/workflow/tracker-config.yaml"]'   "the governance anchor"
# Machine-owned state must outrank the bare `*.md` rule that would otherwise cover it.
probe deny '["TRACKER.md"]'                          "machine-owned board state (TRACKER.md)"
probe deny '["docs/workflow/install-receipt.yaml"]'  "the install receipt"
probe deny '["docs/workflow/code-reviews/v.json"]'   "review verdicts under docs/workflow/"
probe deny '["docs/workflow/pillar-matrices/m.yaml"]' "pillar matrices under docs/workflow/"
probe deny '[".env"]'                                "secret material (.env)"
probe deny '[".env.local"]'                          "secret material (.env.local)"
probe deny '["WORKFLOW-config.yaml"]'                "live Path Gate enforcement controls"
probe deny '[".npmrc"]'                              "credential-capable package-manager config (.npmrc)"
probe deny '[".yarnrc.yml"]'                         "credential-capable package-manager config (.yarnrc.yml)"
probe deny '[".claude/settings.json"]'               "agent harness policy (.claude/)"
probe deny '[".github/workflows/ci.yml"]'            "executable CI policy (.github/workflows/)"
probe deny '[".github/CODEOWNERS"]'                  "review ownership policy (.github/CODEOWNERS)"
probe deny '["CODEOWNERS"]'                          "review ownership policy (root CODEOWNERS)"
probe deny '[".devcontainer/devcontainer.json"]'     "executable development-container policy"
probe deny '["package.json"]'                       "dependency and executable-script manifest"
probe deny '["pyproject.toml"]'                     "dependency and build manifest"
probe deny '["uv.lock"]'                            "dependency lockfile"
probe deny '["Makefile"]'                           "executable build manifest"
probe deny '["Dockerfile"]'                         "executable container manifest"
probe deny '["tsconfig.json"]'                      "application tooling configuration"
probe deny '[".eslintrc.json"]'                     "application tooling configuration"
probe deny '["requirements/dev.txt"]'               "nested path that must not match a root wildcard"
probe deny '["tsconfig/app.json"]'                  "nested path that must not match a root wildcard"
probe deny '[".eslintrc/custom.json"]'              "nested path that must not match a root wildcard"
probe deny '["Docs/api.py"]'                        "case-variant application directory on a case-sensitive checkout"
probe deny '[".Vscode/settings.json"]'              "case-variant editor directory on a case-sensitive checkout"
# Prose rules are ROOT-ONLY (plus docs/). A markdown-authored application — this plugin's own
# `commands/*.md` and `skills/*/SKILL.md` are shipped program text — must not hand an agent its
# instruction set to rewrite unclaimed.
probe deny '["src/module/NOTES.md"]'                 "markdown nested in the source tree"
probe deny '["commands/think.md"]'                   "markdown that IS the application (a command playbook)"
probe deny '["skills/idc-review/SKILL.md"]'          "markdown that IS the application (a skill body)"
probe deny '["src/app.py","README.md"]'              "a MIXED request carrying application code"
probe deny '["."]'                                   "the whole-repository target"

# ── D. the git commit door inherits the same answer ───────────────────────────────────────────────
python3 "$GIT_GATE" install-hooks --repo "$REPO" --plugin-root "$GOV_PLUGIN" >/dev/null 2>&1 \
  || gov_fail "could not install the git path-gate hooks into the fixture"

printf 'node_modules/\n' >> "$REPO/.gitignore"
printf '{"editor.formatOnSave":true}\n' > "$REPO/.vscode/settings.json"
git -C "$REPO" add .gitignore .vscode/settings.json
git -C "$REPO" commit -qm 'chore: adjust local configuration' >/dev/null 2>&1 \
  || gov_fail "the commit door refused a configuration-only commit — the Write door being open is undone at commit time"
git -C "$REPO" push origin main >/dev/null 2>&1 \
  || gov_fail "the push door refused a low-risk desk-only history — the commit door being open is undone at push time"

printf 'print("changed")\n' > "$REPO/src/app.py"
printf 'mixed\n' >> "$REPO/README.md"
git -C "$REPO" add src/app.py README.md
if git -C "$REPO" commit -qm 'feat: mixed desk and application change' >/dev/null 2>&1; then
  gov_fail "the commit door admitted a MIXED request because README.md rode with unauthorized application code"
fi
git -C "$REPO" reset -q HEAD src/app.py README.md

git -C "$REPO" add src/app.py
git -C "$REPO" commit --no-verify -qm 'test: bypass pre-commit for push-door proof'
if git -C "$REPO" push origin main >/dev/null 2>&1; then
  gov_fail "the push door admitted an unauthorized application-code history"
fi
git -C "$REPO" reset --hard -q origin/main

# ── E. the REAL PreToolUse door agrees ────────────────────────────────────────────────────────────
# The door an operator actually hits is the Write/Edit interlock, not the core CLI. Two contract
# details this lane pins by construction, because getting either wrong silently turns the probe into
# a vacuous pass: the wrapper repo-gates on the SHELL's cwd (so it must be invoked from inside the
# fixture, or it fast-exits 0 before python ever runs), and a deny is JSON on stdout — parsed here,
# never string-matched, because the emitted spacing is not part of any contract.
INTERLOCK="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate_hook.sh"
[ -f "$INTERLOCK" ] || gov_fail "idc_interlock_gate_hook.sh not found at $INTERLOCK"

door() { # door <expect: allow|deny> <repo-relative path> <label>
  local expect="$1" rel="$2" label="$3" out verdict
  out=$(cd "$REPO" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/%s","old_string":"a","new_string":"b"},"cwd":"%s"}' "$REPO" "$rel" "$REPO" \
        | IDC_HOOKS_STRICT=1 bash "$INTERLOCK" "$GOV_PLUGIN" 2>&1)
  verdict=$(printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow"); raise SystemExit
try:
    print("deny" if json.loads(raw)["hookSpecificOutput"]["permissionDecision"] == "deny" else "allow")
except Exception:
    print("unparseable")')
  [ "$verdict" = "unparseable" ] && gov_fail "the PreToolUse door emitted output that is neither empty nor a decision JSON for $label: $out"
  [ "$verdict" = "$expect" ] || gov_fail "the PreToolUse door returned '$verdict' for $label, expected '$expect'"
}

# CONTROL first: if the door denies nothing, every allow below is vacuous.
door deny  "src/app.py"                        "CONTROL: application code at the Write/Edit door"
door deny  "TRACKER.md"                        "machine-owned state at the Write/Edit door"
door deny  "docs/workflow/tracker-config.yaml" "the governance anchor at the Write/Edit door"
door deny  ".env"                              "secret material at the Write/Edit door"
door deny  ".github/workflows/ci.yml"          "executable CI policy at the Write/Edit door"
door deny  ".npmrc"                            "credential-capable config at the Write/Edit door"
door deny  "WORKFLOW-config.yaml"              "live Path Gate enforcement controls at the Write/Edit door"
door allow ".vscode/settings.json"             "editor preferences at the Write/Edit door"
door allow "README.md"                         "root prose at the Write/Edit door"
door allow ".gitignore"                        "repository plumbing at the Write/Edit door"
door allow "docs/adr/0001-choice.md"           "project documentation at the Write/Edit door"

echo "PASS: the Path Gate frees low-risk docs/editor/repository desk surfaces while application code, executable policy, dependency/build configuration, credentials, governance anchors and machine state stay gated (core, Write/Edit, commit and push doors agree)"
