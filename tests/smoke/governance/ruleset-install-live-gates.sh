#!/bin/bash
# idc-assert-class: behavior
# ruleset-install-live-gates.sh — W2 + W3: the installer's `--apply` path must bind its certification
# to REALITY on the target repository, not just to the contents of a local file.
#
# The checker (`scripts/idc_ruleset_check.py`) is HERMETIC BY DESIGN — it validates CODEOWNERS CONTENT
# and has no target repo to interrogate. That is the right shape for a checker, but it leaves two
# false-certify vectors that only the installer can close, because only the installer knows which
# GitHub repo is about to be mutated:
#
#   W2  PRINCIPALS. Ownership coverage proves the FILE names an owner for every protected surface. It
#       cannot prove those owners EXIST or hold write access. A rule naming a deleted/renamed handle,
#       a team that was never granted the repo, or a collaborator downgraded to read binds NO reviewer
#       on GitHub, so `require_code_owner_review` installs over nothing while the receipt reads green.
#
#   W3  DEFAULT BRANCH. GitHub enforces CODEOWNERS from the default branch ONLY. The local resolution
#       (F44) proves the validation ref RESOLVES here, not that it is the branch GitHub ENFORCES: a
#       `--default-branch` may name any locally-resolving commit-ish (a SHA, a PR head, a feature
#       branch), and `origin/HEAD` goes stale when the repo's default branch is renamed. Either way
#       `git show` validates bytes GitHub is not enforcing.
#
# HERMETIC: a canned `gh` stub is placed FIRST on PATH and every response is driven by STUB_* env
# vars, so no network call is made and no real repository is contacted. The target repo name is
# deliberately FICTIONAL (`idc-stub-owner/idc-stub-target`) — belt and braces, so that even if the
# stub were somehow bypassed, a real `gh` would 404 rather than mutate anything that exists.
#
# The stub LOGS every invocation, which is what lets the last case assert the strongest form of the
# dry-run contract: dry-run makes ZERO gh calls, proven by an EMPTY log, not merely by exiting 0.
#
# Red-when-broken: delete the `live_default_branch_problem` call and cases W3b/W3c/W3e certify; delete
# the `verify_owner_principals` call and cases W2a/W2b/W2d/W2e/W2f/W2g certify; move either gate out
# of its `if args.apply:` guard and the dry-run case's log is no longer empty.
#
# Usage: bash tests/smoke/governance/ruleset-install-live-gates.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
INS="$PLUGIN/scripts/idc_ruleset_install.py"
RS="$PLUGIN/.github/rulesets/idc-pathway-integrity.json"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$INS" ] || fail "missing installer: scripts/idc_ruleset_install.py"
[ -f "$RS" ]  || fail "missing ruleset: .github/rulesets/idc-pathway-integrity.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A repo that DOES NOT EXIST on GitHub. The stub answers for it; a stub bypass cannot mutate anything.
REPO="idc-stub-owner/idc-stub-target"

# --- the canned gh stub ---------------------------------------------------------------------------
STUB_BIN="$WORK/stubbin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/bin/bash
# Canned `gh` for the hermetic live-gate tests. Every response is driven by STUB_* env vars; every
# invocation is logged to $STUB_LOG so a test can assert that NO call was made at all.
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"

if [ "${STUB_FAIL_ALL:-0}" = "1" ]; then
  echo "gh: connection refused (stub hard failure)" >&2
  exit 1
fi

# The ruleset mutation itself (POST/PUT ... --input -). Matched first: it carries no api path we parse.
case " $* " in
  *" --method "*) echo '{"id":1,"name":"idc-pathway-integrity"}'; exit 0 ;;
esac

# The api path is the sole argument shaped like one (flags and the `Accept:` header value are skipped).
path=""
for a in "$@"; do
  case "$a" in
    repos/*|orgs/*) path="$a" ;;
  esac
done

# Principal-endpoint-only failure modes, so a gh failure can be isolated to the W2 gate without also
# tripping the W3 gate that runs before it.
case "$path" in
  */collaborators/*/permission|orgs/*/teams/*/repos/*)
    if [ "${STUB_FAIL_PRINCIPALS:-0}" = "1" ]; then
      echo "gh: connection reset by peer (stub)" >&2; exit 1
    fi
    if [ "${STUB_NONJSON_PRINCIPALS:-0}" = "1" ]; then
      echo "<html>502 Bad Gateway</html>"; exit 0
    fi
    ;;
esac

case "$path" in
  */collaborators/*/permission)
    user="${path#*/collaborators/}"; user="${user%/permission}"
    case " ${STUB_MISSING_USERS:-} " in
      *" $user "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    case " ${STUB_READONLY_USERS:-} " in
      *" $user "*) printf '{"permission":"read","role_name":"read"}\n'; exit 0 ;;
    esac
    printf '{"permission":"%s","role_name":"%s"}\n' "${STUB_USER_PERM:-write}" "${STUB_USER_ROLE:-write}"
    exit 0 ;;
  orgs/*/teams/*/repos/*)
    team="${path#orgs/*/teams/}"; team="${team%%/repos/*}"
    case " ${STUB_MISSING_TEAMS:-} " in
      *" $team "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    case " ${STUB_READONLY_TEAMS:-} " in
      *" $team "*) printf '{"permissions":{"pull":true,"triage":true,"push":false,"maintain":false,"admin":false}}\n'; exit 0 ;;
    esac
    # A malformed body carrying the permission flags as JSON STRINGS rather than booleans. Every value
    # here means "no write access", but the STRING "false" is truthy in Python.
    if [ -n "${STUB_STRING_PERMS:-}" ]; then
      printf '{"permissions":{"pull":"true","push":"false","maintain":"false","admin":"false"}}\n'
      exit 0
    fi
    printf '{"permissions":{"pull":true,"push":true,"maintain":false,"admin":false}}\n'
    exit 0 ;;
  */rulesets|*/rulesets/*)
    echo '[]'; exit 0 ;;
  */branches/*)
    printf '{"commit":{"sha":"%s"}}\n' "${STUB_BRANCH_SHA:-0000000000000000000000000000000000000000}"
    exit 0 ;;
  repos/*)
    printf '{"default_branch":"%s"}\n' "${STUB_DEFAULT_BRANCH:-main}"
    exit 0 ;;
esac
echo "gh: stub has no canned response for: $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/gh"

# Self-check the stub before trusting a single assertion to it: a stub that silently mis-parses would
# make every REFUSE below pass for the wrong reason (the installer refusing a malformed response
# rather than the vector under test).
probe="$(PATH="$STUB_BIN:$PATH" STUB_DEFAULT_BRANCH=trunk gh api "repos/$REPO")" \
  || fail "stub self-check: the gh stub failed on a plain repo read"
printf '%s' "$probe" | grep -Fq '"default_branch":"trunk"' \
  || fail "stub self-check: repo read did not honor STUB_DEFAULT_BRANCH; got: $probe"
probe="$(PATH="$STUB_BIN:$PATH" gh api "repos/$REPO/collaborators/alice/permission")" \
  || fail "stub self-check: the gh stub failed on a collaborator read"
printf '%s' "$probe" | grep -Fq '"permission":"write"' \
  || fail "stub self-check: collaborator read did not return a write grant; got: $probe"
probe="$(PATH="$STUB_BIN:$PATH" gh api -H "Accept: application/vnd.github.v3.repository+json" \
          "orgs/acme/teams/reviewers/repos/$REPO")" \
  || fail "stub self-check: the gh stub failed on a team-repo read"
printf '%s' "$probe" | grep -Fq '"push":true' \
  || fail "stub self-check: team read did not return a push grant; got: $probe"
PATH="$STUB_BIN:$PATH" STUB_MISSING_USERS="ghost" gh api "repos/$REPO/collaborators/ghost/permission" >/dev/null 2>&1 \
  && fail "stub self-check: a STUB_MISSING_USERS handle did not 404"

# --- fixtures --------------------------------------------------------------------------------------
# A checkout of $REPO whose COMMITTED CODEOWNERS covers all seven protected surfaces, owned by $2.
# origin/HEAD -> origin/main, as a real clone carries.
mk_target() {  # $1=dir  $2=owner token for every rule
  git init -q -b main "$1"
  git -C "$1" config user.email idc-test@example.com
  git -C "$1" config user.name "IDC Test"
  git -C "$1" config commit.gpgsign false
  git -C "$1" remote add origin "git@github.com:$REPO.git"
  echo placeholder > "$1/README.md"
  mkdir -p "$1/.github"
  cat > "$1/.github/CODEOWNERS" <<CO
/.github/workflows/ $2
/scripts/hooks/ $2
/scripts/idc_validation_contract.py $2
/scripts/idc_receipt_check.py $2
/scripts/idc_pathway_check.py $2
/.github/rulesets/ $2
/.github/CODEOWNERS $2
CO
  git -C "$1" add -A
  git -C "$1" commit -q -m init >/dev/null 2>&1
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse HEAD)"
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

TGT_USER="$WORK/tgt-user";  mk_target "$TGT_USER" "@alice"
TGT_TEAM="$WORK/tgt-team";  mk_target "$TGT_TEAM" "@acme/reviewers"
TGT_MAIL="$WORK/tgt-email"; mk_target "$TGT_MAIL" "dev@example.com"
SHA_USER="$(git -C "$TGT_USER" rev-parse HEAD)"
SHA_TEAM="$(git -C "$TGT_TEAM" rev-parse HEAD)"
SHA_MAIL="$(git -C "$TGT_MAIL" rev-parse HEAD)"

# apply <repo-root> <expected-tip-sha> [extra args...] — run --apply with the stub on PATH.
# The stub is told the branch tip that MATCHES the checkout, so the W3 staleness guard is satisfied by
# default and each case below varies exactly one thing.
apply() {
  local root="$1" sha="$2"; shift 2
  PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$sha" \
    python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$root" --apply "$@" 2>&1
}

# --- W3: the validation ref must be GitHub's live default branch ------------------------------------

# (W3a) CLEAN PASS — origin/HEAD names the live default branch and the local tip matches the remote
#       tip, so apply proceeds all the way through the (stubbed) mutation.
out="$(apply "$TGT_USER" "$SHA_USER")" \
  || fail "W3a: apply REFUSED a checkout whose origin/HEAD names the live default branch at the same tip; got: $out"
printf '%s\n' "$out" | grep -qiE '^OK: ruleset' \
  || fail "W3a: apply did not report the ruleset was created; got: $out"

# (W3b) STALE origin/HEAD — GitHub's default branch was renamed to `trunk` while this checkout still
#       points origin/HEAD at origin/main. `main` still resolves locally, so F44's local check is
#       satisfied; only a live read catches it. Red-when-broken: without the live gate the installer
#       validates main's CODEOWNERS and certifies a branch GitHub does not enforce.
out="$(PATH="$STUB_BIN:$PATH" STUB_DEFAULT_BRANCH=trunk STUB_BRANCH_SHA="$SHA_USER" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W3b: apply CERTIFIED via a STALE origin/HEAD (origin/main) while GitHub's default branch is trunk"
printf '%s\n' "$out" | grep -Fq 'trunk' \
  || fail "W3b: the stale-origin/HEAD refusal must name GitHub's live default branch; got: $out"
printf '%s\n' "$out" | grep -qiE 'set-head|stale' \
  || fail "W3b: the stale-origin/HEAD refusal must point at \`git remote set-head origin -a\`; got: $out"

# (W3c) OVERRIDE NAMES A NON-DEFAULT BRANCH — `--default-branch add-governance` resolves locally
#       (F44 is satisfied) but is not the branch GitHub enforces. Red-when-broken: without the live
#       gate any locally-resolving commit-ish — a feature branch, a PR head, a raw SHA — is accepted.
git -C "$TGT_USER" branch -q add-governance
out="$(apply "$TGT_USER" "$SHA_USER" --default-branch add-governance)" \
  && fail "W3c: apply ACCEPTED --default-branch add-governance while GitHub's default branch is main"
printf '%s\n' "$out" | grep -Fq 'main' \
  || fail "W3c: the wrong-override refusal must name the live default branch; got: $out"

# (W3c2) A raw SHA is likewise refused — it resolves perfectly but names no branch at all.
out="$(apply "$TGT_USER" "$SHA_USER" --default-branch "$SHA_USER")" \
  && fail "W3c2: apply ACCEPTED a raw SHA as --default-branch — a SHA is not the default branch"

# (W3d) CONTROL — the override naming the live default branch PASSES, in both accepted spellings.
#       This proves the gate selects the right ref rather than refusing every override.
out="$(apply "$TGT_USER" "$SHA_USER" --default-branch main)" \
  || fail "W3d: apply REFUSED --default-branch main, which IS the live default branch; got: $out"
out="$(apply "$TGT_USER" "$SHA_USER" --default-branch origin/main)" \
  || fail "W3d: apply REFUSED --default-branch origin/main, the remote-tracking spelling of the live default; got: $out"

# (W3e) STALE CHECKOUT — the ref names the right branch but the local tip differs from GitHub's, so
#       `git show` would validate bytes GitHub is not enforcing. Red-when-broken: without the tip
#       comparison an out-of-date clone certifies whatever CODEOWNERS it happens to hold.
out="$(apply "$TGT_USER" "cafebabe00000000000000000000000000000000")" \
  && fail "W3e: apply CERTIFIED a STALE checkout whose local tip differs from GitHub's default-branch tip"
printf '%s\n' "$out" | grep -qiE 'stale|fetch' \
  || fail "W3e: the stale-checkout refusal must say the checkout is stale / to git fetch; got: $out"

# (W3f) GIT-REPLACE TAMPER — the tip check compares `rev-parse`'s oid against GitHub's and passes,
#       but a `refs/replace/<oid>` ref rewires OBJECT lookup so `git show` returns a DIFFERENT commit's
#       bytes. The two commands disagree, and the installer runs exactly that pair: it vouched for the
#       real tip and then certified attacker-chosen content, printing `OK: ruleset created` over a repo
#       binding NO reviewer for six of the seven protected surfaces.
#
#       The fixture: commit A covers only ONE surface (so it MUST be refused on ownership grounds);
#       commit B covers all seven. The branch and origin/main stay at A, GitHub is told the tip is A —
#       so every other gate is satisfied — and `git replace A B` is installed. If content is read
#       through the replace ref, the installer sees B's full coverage and certifies.
#
#       Red-when-broken: drop `--no-replace-objects`/GIT_NO_REPLACE_OBJECTS from `_git` and this case
#       prints `OK: ruleset ... created` instead of refusing. Note that PINNING THE OID DOES NOT FIX
#       THIS — `git show <full-oid>:<path>` follows the replace ref too, because replacement is applied
#       at object lookup, below ref resolution. Only refusing to read replacement refs closes it.
TGT_REPL="$WORK/tgt-replace"; mk_target "$TGT_REPL" "@alice"
# A = the tip GitHub knows about; its CODEOWNERS covers ONE surface only.
cat > "$TGT_REPL/.github/CODEOWNERS" <<'CO'
/.github/CODEOWNERS @alice
CO
git -C "$TGT_REPL" add -A
git -C "$TGT_REPL" commit -q -m "narrow codeowners (the bytes GitHub enforces)"
SHA_REPL_A="$(git -C "$TGT_REPL" rev-parse HEAD)"
# B = full seven-surface coverage, committed then rewound out of the branch.
cat > "$TGT_REPL/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @alice
/scripts/hooks/ @alice
/scripts/idc_validation_contract.py @alice
/scripts/idc_receipt_check.py @alice
/scripts/idc_pathway_check.py @alice
/.github/rulesets/ @alice
/.github/CODEOWNERS @alice
CO
git -C "$TGT_REPL" add -A
git -C "$TGT_REPL" commit -q -m "wide codeowners (never on the enforced branch)"
SHA_REPL_B="$(git -C "$TGT_REPL" rev-parse HEAD)"
git -C "$TGT_REPL" reset -q --hard "$SHA_REPL_A"
git -C "$TGT_REPL" update-ref refs/remotes/origin/main "$SHA_REPL_A"
git -C "$TGT_REPL" replace "$SHA_REPL_A" "$SHA_REPL_B"
# The WORKING TREE is left holding B's wide content (uncommitted). This is what makes the case prove a
# genuine FALSE-CERTIFY rather than a lucky save by a neighbouring gate: with the guard REMOVED,
# `git show` returns B, the working-tree-vs-committed divergence gate sees B == B and passes, ownership
# sees all seven surfaces covered and passes, and `--apply` prints `OK: ruleset ... created` over a repo
# whose ENFORCED CODEOWNERS binds a reviewer to exactly one surface. With the guard in place `git show`
# returns A, so the run refuses. (Left committed at A with an A working tree, the divergence gate would
# refuse even with the hole open, and this case would pass for the wrong reason.)
cat > "$TGT_REPL/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @alice
/scripts/hooks/ @alice
/scripts/idc_validation_contract.py @alice
/scripts/idc_receipt_check.py @alice
/scripts/idc_pathway_check.py @alice
/.github/rulesets/ @alice
/.github/CODEOWNERS @alice
CO
# Prove the fixture is REAL before asserting on it: without the guard, `git show` must actually hand
# back B's bytes while `rev-parse` still reports A. A fixture that does not diverge would make the
# assertion below pass for the wrong reason.
[ "$(git -C "$TGT_REPL" rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}')" = "$SHA_REPL_A" ] \
  || fail "W3f fixture: origin/main no longer resolves to commit A — the tamper fixture is not set up as intended"
git -C "$TGT_REPL" show "refs/remotes/origin/main:.github/CODEOWNERS" | grep -Fq '/scripts/hooks/' \
  || fail "W3f fixture: \`git show\` did NOT follow the replace ref, so this case cannot prove the guard works"
git -C "$TGT_REPL" --no-replace-objects show "refs/remotes/origin/main:.github/CODEOWNERS" | grep -Fq '/scripts/hooks/' \
  && fail "W3f fixture: \`--no-replace-objects\` still returned the substituted bytes — the fixture is not a replace-ref tamper"
out="$(apply "$TGT_REPL" "$SHA_REPL_A")" \
  && fail "W3f: apply CERTIFIED through a \`git replace\` ref — it validated a substituted commit's CODEOWNERS while the tip check vouched for the real one; got: $out"
printf '%s\n' "$out" | grep -qiE '^OK: ruleset' \
  && fail "W3f: apply reported the ruleset was created over a repo whose ENFORCED CODEOWNERS binds one surface; got: $out"
printf '%s\n' "$out" | grep -qiE '^REFUSE:' \
  || fail "W3f: apply must REFUSE the replace-ref tamper via this module's refusal convention; got: $out"

# --- W2: every owner principal must exist and hold write-or-better access ---------------------------

# (W2a) NONEXISTENT USER — the handle 404s (deleted, renamed, or never a collaborator).
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_MISSING_USERS="alice" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2a: apply CERTIFIED a CODEOWNERS naming a user GitHub cannot resolve"
printf '%s\n' "$out" | grep -Fq 'alice' \
  || fail "W2a: the unresolvable-owner refusal must name the owner; got: $out"

# (W2b) READ-ONLY USER — the account exists but cannot approve as a code owner.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_READONLY_USERS="alice" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2b: apply CERTIFIED a CODEOWNERS whose owner has only READ access"
printf '%s\n' "$out" | grep -qiE 'write|read' \
  || fail "W2b: the read-only-owner refusal must explain the missing write access; got: $out"

# (W2c) CONTROL — a TEAM owner with push access PASSES, so the team path is verified, not blanket-refused.
out="$(apply "$TGT_TEAM" "$SHA_TEAM")" \
  || fail "W2c: apply REFUSED a team owner that holds push access on the repo; got: $out"

# (W2d) MISSING TEAM — 404 covers all three indistinguishable cases (absent, invisible, ungranted).
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_TEAM" STUB_MISSING_TEAMS="reviewers" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_TEAM" --apply 2>&1)" \
  && fail "W2d: apply CERTIFIED a CODEOWNERS naming a team that does not resolve on the repo"
printf '%s\n' "$out" | grep -Fq 'acme/reviewers' \
  || fail "W2d: the missing-team refusal must name the team; got: $out"

# (W2e) READ-ONLY TEAM — resolves, but with pull/triage only.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_TEAM" STUB_READONLY_TEAMS="reviewers" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_TEAM" --apply 2>&1)" \
  && fail "W2e: apply CERTIFIED a team owner holding only read/triage access"

# (W2e2) STRING-VALUED PERMISSION FLAGS — a malformed/proxied body returns `"push":"false"` instead of
#        the documented boolean. Every flag says NO write access, but `bool("false")` is True in
#        Python, so a truthiness test reads the team as writable and certifies. Only a real `true`
#        may count. Red-when-broken: use `bool(perms.get(k))` and this case CERTIFIES.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_TEAM" STUB_STRING_PERMS=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_TEAM" --apply 2>&1)" \
  && fail "W2e2: apply CERTIFIED a team whose permissions came back as the STRING \"false\" — a truthy string is not a write grant; got: $out"
printf '%s\n' "$out" | grep -Fq 'acme/reviewers' \
  || fail "W2e2: the string-permissions refusal must name the team; got: $out"

# (W2f) EMAIL OWNER — GitHub exposes no API that resolves an email owner to a user with access, so it
#       is live-UNVERIFIABLE and refused at apply (fail closed, consistent with F41's philosophy).
#       Note the checker accepts the email FORM; this gate is strictly about live verifiability.
out="$(apply "$TGT_MAIL" "$SHA_MAIL")" \
  && fail "W2f: apply CERTIFIED an email owner, which cannot be verified against the live repo"
printf '%s\n' "$out" | grep -Fq 'dev@example.com' \
  || fail "W2f: the email-owner refusal must name the owner; got: $out"
printf '%s\n' "$out" | grep -qiE '@handle|@org/team|handle' \
  || fail "W2f: the email-owner refusal should suggest @handles / @org-team; got: $out"

# (W2g) GH HARD FAILURE on the principal endpoints — network error / auth failure / rate limit. Fail
#       closed: an unverifiable principal is refused, never assumed good.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_FAIL_PRINCIPALS=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2g: apply CERTIFIED when the principal lookup FAILED — an unverifiable owner must fail closed"

# (W2h) NON-JSON body (a proxy error page, an HTML 502). The JSON decode must refuse, not crash.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_NONJSON_PRINCIPALS=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2h: apply CERTIFIED when the principal endpoint returned a non-JSON body"
printf '%s\n' "$out" | grep -qi 'traceback' \
  && fail "W2h: a non-JSON principal response produced a TRACEBACK instead of a clean refusal; got: $out"

# (W2i) A gh hard failure ANYWHERE (including the default-branch read) also fails closed.
out="$(PATH="$STUB_BIN:$PATH" STUB_FAIL_ALL=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2i: apply CERTIFIED while every gh call failed"

# (W2j) `gh` NOT INSTALLED AT ALL — a bare PATH with no gh on it. `gh failed` and `gh is absent` are
#       different errors: the first is a non-zero exit this module already converts, the second raises
#       OSError out of subprocess.run. It must fail closed through this module's own REFUSE convention,
#       not escape as a raw traceback past the gates. Red-when-broken: drop the OSError conversion in
#       `_gh_json` and this case prints a FileNotFoundError traceback.
#       PATH keeps python3 AND git — ONLY gh is removed. Dropping git too would make this case refuse
#       at the origin-identity check, long before any gh call, and it would pass without ever
#       exercising the path under test (verified: with git also absent, breaking the OSError
#       conversion left this case GREEN).
BAREPATH="$WORK/barepath"; mkdir -p "$BAREPATH"
ln -sf "$(command -v python3)" "$BAREPATH/python3"
ln -sf "$(command -v git)" "$BAREPATH/git"
command -v gh >/dev/null 2>&1 && [ -e "$BAREPATH/gh" ] \
  && fail "W2j: the bare PATH still carries a gh — this case would not exercise the missing-gh path"
out="$(PATH="$BAREPATH" "$BAREPATH/python3" "$INS" --ruleset "$RS" --repo "$REPO" \
        --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2j: apply CERTIFIED with no \`gh\` on PATH — an unverifiable target must fail closed; got: $out"
printf '%s\n' "$out" | grep -qi 'traceback' \
  && fail "W2j: a missing \`gh\` produced a TRACEBACK instead of this module's REFUSE convention; got: $out"
# Specifically the GH refusal — not the git-absent / identity refusal, which would prove nothing here.
printf '%s\n' "$out" | grep -Fq 'could not invoke gh' \
  || fail "W2j: a missing \`gh\` must refuse with this module's 'could not invoke gh' message (a different refusal means this case never reached the gh call); got: $out"

# --- the dry-run contract: NO network calls, at all -------------------------------------------------
# The strongest available form of the assertion: run dry-run with the stub on PATH and a LOG, then
# require the log to be EMPTY. Exiting 0 would not be enough — it would still pass if the gates ran
# and happened to succeed. STUB_FAIL_ALL=1 is belt and braces: any call at all would also break it.
DRY_LOG="$WORK/dry-run-gh-calls.log"
: > "$DRY_LOG"
out="$(PATH="$STUB_BIN:$PATH" STUB_LOG="$DRY_LOG" STUB_FAIL_ALL=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" 2>&1)" \
  || fail "dry-run REFUSED a covered target — dry-run must stay local-only and succeed; got: $out"
if [ -s "$DRY_LOG" ]; then
  echo "--- gh calls made during dry-run:"; cat "$DRY_LOG"
  fail "dry-run made NETWORK calls — the live gates must be inside \`if args.apply:\` (dry-run makes no network calls)"
fi
printf '%s\n' "$out" | grep -qiE 'note:.*(apply|live)' \
  || fail "dry-run must print a note that the live gates run at --apply; got: $out"

# And the control: the SAME invocation with --apply DOES call gh (so the empty log above is a real
# property of dry-run, not a stub that never logs anything).
: > "$DRY_LOG"
PATH="$STUB_BIN:$PATH" STUB_LOG="$DRY_LOG" STUB_BRANCH_SHA="$SHA_USER" \
  python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply >/dev/null 2>&1
[ -s "$DRY_LOG" ] \
  || fail "the stub log stayed EMPTY even under --apply — the log is not recording, so the dry-run assertion proves nothing"

echo "PASS: the installer's --apply path binds certification to the live repository (W2+W3) — the validation ref must NAME GitHub's live default branch (a stale origin/HEAD, a non-default override, and a raw SHA are all refused; both \`D\` and \`origin/D\` spellings pass) and the local checkout must be at the same tip; every CODEOWNERS owner principal must resolve with write-or-better access (missing/read-only user, missing/read-only team, an email owner, a gh failure, and a non-JSON body each refuse fail-closed); and dry-run still makes ZERO gh calls"
