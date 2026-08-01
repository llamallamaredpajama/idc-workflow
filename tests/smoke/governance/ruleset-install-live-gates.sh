#!/bin/bash
# idc-assert-class: behavior
# ruleset-install-live-gates.sh — W2 + W3: the installer's `--apply` path must bind its certification
# to REALITY on the target repository, not just to the contents of a local file.
#
# These two gates live in the INSTALLER, not the checker. The reason is not that the checker cannot
# reach the network — it can (`idc_ruleset_check.py --repo OWNER/REPO`, combinable with --repo-root).
# It is that `--repo` there is OPTIONAL, so any gate hung off it is skipped by simply not passing the
# flag. The installer is about to MUTATE a named repository, so it always knows the target and can
# refuse UNCONDITIONALLY. Two false-certify vectors follow from that:
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
# The QUERY STRING is split off the path but kept: the installer/checker page list endpoints with
# `?per_page=N&page=N`, and a stub that folded the query into the path would stop matching them (and
# would silently answer the repo-object response instead — a stub bug that reads as a code bug).
path=""; query=""
for a in "$@"; do
  case "$a" in
    repos/*|orgs/*) path="${a%%\?*}"; case "$a" in *\?*) query="${a#*\?}" ;; *) query="" ;; esac ;;
  esac
done
# The page number the caller asked for (default 1), for the pagination cases.
page=1
case "$query" in
  *page=*) page="${query##*page=}"; page="${page%%&*}" ;;
esac

# WRONG-SHAPE bodies: valid JSON that is not the documented STRUCTURE. `_gh_json` guarantees the first,
# never the second, so each of these used to reach a `["id"]` / `.get` on the wrong type and raise
# KeyError/AttributeError — a raw traceback where the module's header promises a REFUSE (F16).
case "$path" in
  */rulesets)
    # PAGE-AWARE, and it must stay that way: the walk ends only on an EMPTY page, so a listing mode
    # that answers the same non-empty body for EVERY page never terminates. Answering the malformed
    # entry on page one and `[]` afterwards is also what a real backend does, and it keeps this case
    # refusing on the MISSING ID rather than on the walker's page ceiling.
    if [ "${STUB_RULESET_NO_ID:-0}" = "1" ]; then
      if [ "$page" = "1" ]; then echo '[{"name":"idc-pathway-integrity"}]'; else echo '[]'; fi
      exit 0
    fi
    [ "${STUB_RULESET_DICT:-0}" = "1" ] && { echo '{"id":1,"name":"idc-pathway-integrity"}'; exit 0; }
    ;;
  */branches/*)
    [ "${STUB_BRANCH_BAD_SHAPE:-0}" = "1" ] && { echo '{"commit":"abc"}'; exit 0; }
    ;;
esac

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
    [ "${STUB_PRINCIPAL_BAD_SHAPE:-0}" = "1" ] && { echo '["not","an","object"]'; exit 0; }
    user="${path#*/collaborators/}"; user="${user%/permission}"
    case " ${STUB_MISSING_USERS:-} " in
      *" $user "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    case " ${STUB_READONLY_USERS:-} " in
      *" $user "*) printf '{"permission":"read","role_name":"read"}\n'; exit 0 ;;
    esac
    # STUB_USER_CAPS: "" = omit the boolean capability map entirely (a body with NO authoritative
    # access statement); "push"/"none" = emit user.permissions with that capability true/all false.
    caps=""
    case "${STUB_USER_CAPS:-}" in
      push)     caps=',"user":{"permissions":{"pull":true,"triage":true,"push":true,"maintain":false,"admin":false}}' ;;
      maintain) caps=',"user":{"permissions":{"pull":true,"triage":true,"push":true,"maintain":true,"admin":false}}' ;;
      none)     caps=',"user":{"permissions":{"pull":true,"triage":false,"push":false,"maintain":false,"admin":false}}' ;;
    esac
    if [ -z "${STUB_USER_PERM-unset}" ] && [ "${STUB_USER_PERM+set}" = "set" ]; then
      # explicitly empty permission -> omit the legacy field entirely
      printf '{"role_name":"%s"%s}\n' "${STUB_USER_ROLE:-write}" "$caps"
    else
      printf '{"permission":"%s","role_name":"%s"%s}\n' "${STUB_USER_PERM:-write}" "${STUB_USER_ROLE:-write}" "$caps"
    fi
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
  */rulesets)
    # The LISTING. Modes:
    #   default                     -> empty, so the installer takes the POST/create branch
    #   STUB_EXISTING_RULESET_ID=N  -> our ruleset already exists, so it must take the PUT/update branch
    #   STUB_RULESETS_PAGES=1       -> our ruleset sits on page 2 behind a FULL page of org-inherited
    #                                  rulesets, so a single-page read would report it absent
    #   STUB_RULESETS_SHORT=1       -> the backend IGNORES per_page and serves its documented 30-item
    #                                  DEFAULT page, with our ruleset on page 2 (F36)
    #   STUB_RULESETS_NULL=1        -> exits 0 with an EMPTY BODY: valid to `gh`, `None` after the JSON
    #                                  decode, and NOT proof that no ruleset is installed (F34)
    #   STUB_RULESETS_ENDLESS=1     -> every page is FULL, so the walk never reaches an empty one (F36)
    # PAST THE LAST PAGE GITHUB RETURNS AN EMPTY ARRAY, and an empty page is the ONLY thing that ends
    # the walk, so every paged mode below serves `[]` once its content is exhausted. A mode that
    # instead repeated its last page forever would hang the walker rather than fail it.
    if [ "${STUB_RULESETS_NULL:-0}" = "1" ]; then exit 0; fi
    if [ "${STUB_RULESETS_ENDLESS:-0}" = "1" ]; then
      # Full pages up to 150 — comfortably past the walker's page ceiling, so the CEILING is what
      # stops a correct walker. Beyond 150 the stub ERRORS instead of serving another page: if the
      # ceiling is removed, this case must FAIL LOUDLY on a different message rather than hang a CI
      # lane forever (the trap that killed the prototype stub, recorded in the receipts).
      if [ "$page" -le 150 ] 2>/dev/null; then
        awk 'BEGIN{printf "["; for(i=1;i<=100;i++){printf "%s{\"id\":%d,\"name\":\"org-inherited-%d\"}", (i>1?",":""), 9000+i, i}; printf "]\n"}'
        exit 0
      fi
      echo "gh: stub refuses to serve page $page — the page ceiling should have stopped this walk" >&2
      exit 1
    fi
    if [ "${STUB_RULESETS_SHORT:-0}" = "1" ]; then
      case "$page" in
        1) awk 'BEGIN{printf "["; for(i=1;i<=30;i++){printf "%s{\"id\":%d,\"name\":\"org-inherited-%d\"}", (i>1?",":""), 7000+i, i}; printf "]\n"}'; exit 0 ;;
        2) printf '[{"id":%s,"name":"idc-pathway-integrity"}]\n' "${STUB_EXISTING_RULESET_ID:-4242}"; exit 0 ;;
        *) echo '[]'; exit 0 ;;
      esac
    fi
    if [ -n "${STUB_RULESETS_PAGES:-}" ]; then
      case "$page" in
        # Exactly per_page entries (100) of org-inherited noise -> a full page, so there IS a page 2.
        1) awk 'BEGIN{printf "["; for(i=1;i<=100;i++){printf "%s{\"id\":%d,\"name\":\"org-inherited-%d\"}", (i>1?",":""), 9000+i, i}; printf "]\n"}'; exit 0 ;;
        2) printf '[{"id":%s,"name":"idc-pathway-integrity"}]\n' "${STUB_EXISTING_RULESET_ID:-4242}"; exit 0 ;;
        *) echo '[]'; exit 0 ;;
      esac
    fi
    if [ -n "${STUB_EXISTING_RULESET_ID:-}" ] && [ "$page" = "1" ]; then
      printf '[{"id":%s,"name":"idc-pathway-integrity"}]\n' "$STUB_EXISTING_RULESET_ID"
      exit 0
    fi
    echo '[]'; exit 0 ;;
  */rulesets/*)
    echo '{"id":1,"name":"idc-pathway-integrity"}'; exit 0 ;;
  */branches/*)
    printf '{"commit":{"sha":"%s"}}\n' "${STUB_BRANCH_SHA:-0000000000000000000000000000000000000000}"
    exit 0 ;;
  repos/*)
    [ "${STUB_REPO_READ_FAILS:-0}" = "1" ] && { echo "gh: Bad gateway (HTTP 502)" >&2; exit 1; }
    [ "${STUB_REPO_BAD_SHAPE:-0}" = "1" ] && { echo '["not","an","object"]'; exit 0; }
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
# The listing endpoint is now read WITH A QUERY STRING (?per_page=&page=). A stub that folded the query
# into the path would fall through to the repo-object response and every rulesets assertion below would
# be testing the wrong thing, so the paged shape is self-checked explicitly.
probe="$(PATH="$STUB_BIN:$PATH" gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the gh stub failed on a PAGED rulesets listing"
[ "$probe" = "[]" ] \
  || fail "stub self-check: a paged rulesets listing did not return the default empty array; got: $probe"
probe="$(PATH="$STUB_BIN:$PATH" STUB_EXISTING_RULESET_ID=77 gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the gh stub failed on an EXISTING-ruleset listing"
printf '%s' "$probe" | grep -Fq '"id":77' \
  || fail "stub self-check: STUB_EXISTING_RULESET_ID was not honored; got: $probe"
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_PAGES=1 gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the gh stub failed on a full first page"
[ "$(printf '%s' "$probe" | grep -o 'org-inherited-' | wc -l | tr -d ' ')" = "100" ] \
  || fail "stub self-check: the paginated first page must hold exactly per_page(100) entries, or nothing proves a second page is fetched"
printf '%s' "$probe" | grep -Fq 'idc-pathway-integrity' \
  && fail "stub self-check: the paginated FIRST page must NOT contain our ruleset — that is the whole point of the case"
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_PAGES=1 gh api "repos/$REPO/rulesets?per_page=100&page=2")" \
  || fail "stub self-check: the gh stub failed on the second page"
printf '%s' "$probe" | grep -Fq 'idc-pathway-integrity' \
  || fail "stub self-check: the paginated SECOND page must contain our ruleset; got: $probe"
# Past the last page GitHub answers with an EMPTY ARRAY, and that is the only thing that ends the
# walk. A stub that repeated its last page here would HANG the walker instead of failing it.
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_PAGES=1 gh api "repos/$REPO/rulesets?per_page=100&page=3")" \
  || fail "stub self-check: the gh stub failed past the last page"
[ "$probe" = "[]" ] \
  || fail "stub self-check: past the last page the stub must return an EMPTY ARRAY as GitHub does, or the page walk cannot terminate; got: $probe"
# STUB_RULESETS_SHORT: the backend IGNORES per_page and serves its 30-item default (F36).
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_SHORT=1 gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the gh stub failed on a SHORT first page"
[ "$(printf '%s' "$probe" | grep -o 'org-inherited-' | wc -l | tr -d ' ')" = "30" ] \
  || fail "stub self-check: the SHORT page mode must serve exactly 30 entries when 100 were asked for, or it does not model a backend ignoring per_page"
printf '%s' "$probe" | grep -Fq 'idc-pathway-integrity' \
  && fail "stub self-check: the SHORT first page must NOT contain our ruleset — that is the whole point of the case"
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_SHORT=1 gh api "repos/$REPO/rulesets?per_page=100&page=2")" \
  || fail "stub self-check: the gh stub failed on the SHORT second page"
printf '%s' "$probe" | grep -Fq 'idc-pathway-integrity' \
  || fail "stub self-check: the SHORT second page must contain our ruleset; got: $probe"
# Every listing mode must EMPTY OUT past its content, including the wrong-shape ones: the walk ends
# only on an empty page, so a mode repeating one non-empty body for every page never terminates and
# the run refuses at the page ceiling instead of at the gate the case is about.
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESET_NO_ID=1 gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the gh stub failed on a no-id listing"
printf '%s' "$probe" | grep -Fq 'idc-pathway-integrity' \
  || fail "stub self-check: the no-id listing must carry our ruleset name on page one; got: $probe"
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESET_NO_ID=1 gh api "repos/$REPO/rulesets?per_page=100&page=2")" \
  || fail "stub self-check: the gh stub failed past the no-id listing's first page"
[ "$probe" = "[]" ] \
  || fail "stub self-check: the no-id listing mode must EMPTY OUT past page one, or the walk cannot terminate and W4c refuses at the page ceiling instead of on the missing id; got: $probe"
# STUB_RULESETS_NULL: exits 0 with NO output — valid to `gh`, and `None` once decoded (F34).
probe="$(PATH="$STUB_BIN:$PATH" STUB_RULESETS_NULL=1 gh api "repos/$REPO/rulesets?per_page=100&page=1")" \
  || fail "stub self-check: the NULL listing mode must EXIT 0 — a gh failure would refuse for the wrong reason"
[ -z "$probe" ] \
  || fail "stub self-check: the NULL listing mode must produce an EMPTY body; got: $probe"

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
/scripts/idc_ruleset_check.py $2
/scripts/idc_path_gate.py $2
/scripts/idc_git_path_gate.py $2
/scripts/idc_build_receipt.py $2
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

# (W3g) The default-branch cross-check must FAIL CLOSED when the read itself fails. An unreadable
#        live default branch is a failure to VERIFY, never a pass: certifying here would install
#        require_code_owner_review while binding validation to a branch nobody confirmed is enforced —
#        the F39/F44 harm class reached through an unanswered question instead of a wrong answer.
out="$(PATH="$STUB_BIN:$PATH" STUB_REPO_READ_FAILS=1 STUB_BRANCH_SHA="$SHA_USER" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W3g: apply CERTIFIED while the live default-branch read FAILED — an unverifiable default branch must refuse, not pass"
printf '%s\n' "$out" | grep -Fq "cannot read the default branch" \
  || fail "W3g: the refusal must name the unreadable default branch as the cause; got: $out"

# (W3g2) A valid-JSON body of the WRONG SHAPE is likewise refused rather than reaching `.get` (F16).
out="$(PATH="$STUB_BIN:$PATH" STUB_REPO_BAD_SHAPE=1 STUB_BRANCH_SHA="$SHA_USER" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W3g2: apply CERTIFIED against a wrong-shape repository body"
printf '%s\n' "$out" | grep -Fq "refusing to certify" \
  || fail "W3g2: the wrong-shape refusal must say it refuses to certify; got: $out"

# (W3g3) CONTROL — with the stub healthy again the SAME invocation passes, so W3g/W3g2 refused
#        because of the broken read and not because this fixture cannot certify at all.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  || fail "W3g3 CONTROL: the same invocation with a healthy repo read was REFUSED, so W3g/W3g2 prove nothing; got: $out"

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
/scripts/idc_ruleset_check.py @alice
/scripts/idc_path_gate.py @alice
/scripts/idc_git_path_gate.py @alice
/scripts/idc_build_receipt.py @alice
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
/scripts/idc_ruleset_check.py @alice
/scripts/idc_path_gate.py @alice
/scripts/idc_git_path_gate.py @alice
/scripts/idc_build_receipt.py @alice
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
# Pin WHICH gate spoke (F26). A bare `^REFUSE:` is satisfied by any of the eight gates ahead of this
# one, so it would stay green if a fixture drifted and the run started refusing for an unrelated reason.
# On this fixture the replace ref is disabled, so `git show` returns A's NARROW content while the
# working tree holds B's wide content — the divergence gate is the one that must speak. (It is not a
# replace-specific gate because there is no such gate: `_git` removes the divergence rather than
# detecting it, which is exactly why the assertion has to name the observable consequence instead.)
printf '%s\n' "$out" | grep -qiE 'working-tree CODEOWNERS|does not match the copy committed' \
  || fail "W3f: expected the working-tree-vs-committed divergence refusal (the observable consequence of \`git show\` returning the REAL commit A); a different gate speaking means the fixture drifted; got: $out"

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
# Assert what the case actually depends on: that `gh` is NOT resolvable UNDER THE BARE PATH. The old
# form was `[ -e "$BAREPATH/gh" ]`, which could never be true — $BAREPATH is a fresh directory that only
# ever receives python3 and git — so it read as a precondition check while proving nothing. That is the
# repo's recurring silent-guard shape (F29), sitting inside the lane that exists to prevent it (F25).
PATH="$BAREPATH" command -v gh >/dev/null 2>&1 \
  && fail "W2j: \`gh\` IS resolvable under the bare PATH — this case would not exercise the missing-gh path"
# ...and the control that the bare PATH is otherwise usable, so the refusal below is about gh and not
# about a PATH that resolves nothing at all.
PATH="$BAREPATH" command -v git >/dev/null 2>&1 \
  || fail "W2j: the bare PATH cannot resolve \`git\` — the run would refuse at the identity check, long before any gh call"
out="$(PATH="$BAREPATH" "$BAREPATH/python3" "$INS" --ruleset "$RS" --repo "$REPO" \
        --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2j: apply CERTIFIED with no \`gh\` on PATH — an unverifiable target must fail closed; got: $out"
printf '%s\n' "$out" | grep -qi 'traceback' \
  && fail "W2j: a missing \`gh\` produced a TRACEBACK instead of this module's REFUSE convention; got: $out"
# Specifically the GH refusal — not the git-absent / identity refusal, which would prove nothing here.
printf '%s\n' "$out" | grep -Fq 'could not invoke gh' \
  || fail "W2j: a missing \`gh\` must refuse with this module's 'could not invoke gh' message (a different refusal means this case never reached the gh call); got: $out"

# (W2k) MAINTAIN / ADMIN are genuinely accepted — the positive case `_WRITE_OR_BETTER` exists for.
#       Without it, narrowing the set to just {"write"} left this whole lane GREEN: every other case
#       asserts a REFUSAL, and refusals only get MORE likely as the accepted set shrinks. A guard whose
#       narrowing nothing detects is the repo's recurring silent-guard trap (F29), so each accepted
#       value gets a case that goes red if it is dropped.
for perm in maintain admin; do
  out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_USER_PERM="$perm" STUB_USER_ROLE="$perm" \
          python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
    || fail "W2k: apply REFUSED an owner holding '$perm' access — $perm is write-or-better and must satisfy require_code_owner_review; got: $out"
done

# (W2k2) NO-AUTHORITATIVE-FIELD path. When GitHub omits the legacy `permission` field (some GitHub
#        Enterprise versions do), the grant is decided on the BOOLEAN capability map GitHub emits —
#        never on `role_name`, which is a free-form ORG-DEFINED string.
#
# W2k2a — COMPATIBILITY: no `permission`, but the boolean map grants push -> ACCEPTED. This is the
#         real GHE case the old role_name fallback existed to serve, now served without trusting a name.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_USER_PERM="" STUB_USER_CAPS="push" \
        STUB_USER_ROLE="write" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  || fail "W2k2a: apply REFUSED an owner whose body omits \`permission\` but whose boolean permissions map grants push — the GHE-compatibility path must still certify; got: $out"

# W2k2b — NEW-12 CLOSURE: no `permission`, NO boolean map, only a free-form role_name that case-folds
#         to a built-in. An org can define a custom role literally named "maintain" that grants no push
#         at all, so this is not proof of access and must REFUSE.
#         Red-when-broken: restore `granted = ... else role in _WRITE_OR_BETTER` and this CERTIFIES.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_USER_PERM="" STUB_USER_CAPS="" \
        STUB_USER_ROLE="maintain" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2k2b: apply CERTIFIED an owner from a free-form role_name alone — the body carried neither a \`permission\` field nor a boolean permissions map, so nothing proved the owner can approve"
printf '%s\n' "$out" | grep -Fq "free-form" \
  || fail "W2k2b: the refusal must say the role name is not proof of access; got: $out"

# W2k2c — CONTROL: no `permission`, boolean map present but grants nothing, role_name still says
#         "maintain". The booleans decide and the name cannot out-vote them.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_USER_PERM="" STUB_USER_CAPS="none" \
        STUB_USER_ROLE="maintain" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2k2c: apply CERTIFIED an owner whose boolean permissions map grants no write capability, because role_name case-folded to 'maintain'"


# (W2k3) SECURITY CONTROL — `role_name` must NOT out-vote an authoritative `permission`. `role_name`
#        carries ORG-DEFINED CUSTOM ROLE NAMES, which are free-form: an org can define a custom role
#        literally named "maintain" that grants no push at all. When the legacy `permission` field says
#        `read`, that is GitHub's normative answer and the owner cannot approve as a code owner.
#        Red-when-broken: restore the blanket OR (`perm not in W and role not in W`) and this CERTIFIES.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_USER_PERM="read" STUB_USER_ROLE="maintain" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W2k3: apply CERTIFIED an owner whose authoritative permission is 'read' because a free-form role_name case-folded to 'maintain' — a custom role name must not out-vote GitHub's normative field"
printf '%s\n' "$out" | grep -Fq "read" \
  || fail "W2k3: the refusal must report the AUTHORITATIVE permission ('read'), not the role name that was ignored; got: $out"

# --- W4: the idempotent update path, a paginated listing, and wrong-shape bodies ---------------------

# (W4a) EXISTING RULESET -> the PUT/update branch. The stub used to answer `[]` for every listing, so
#       `_existing_ruleset_id` was always None and ONLY the POST/create branch was ever exercised —
#       while the PUT branch is what runs on every re-install of an already-governed repo (F23).
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_EXISTING_RULESET_ID=4242 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  || fail "W4a: apply failed against a repo that already carries the ruleset; got: $out"
printf '%s\n' "$out" | grep -qiE '^OK: ruleset .* updated' \
  || fail "W4a: an already-installed ruleset must be UPDATED (PUT), not re-created; got: $out"
# And the call log proves it was a PUT to the existing id, not a POST.
W4_LOG="$WORK/w4-update.log"; : > "$W4_LOG"
PATH="$STUB_BIN:$PATH" STUB_LOG="$W4_LOG" STUB_BRANCH_SHA="$SHA_USER" STUB_EXISTING_RULESET_ID=4242 \
  python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply >/dev/null 2>&1
grep -Fq -- "--method PUT" "$W4_LOG" \
  || fail "W4a: the mutation was not a PUT; the gh call log was: $(cat "$W4_LOG")"
grep -Fq "rulesets/4242" "$W4_LOG" \
  || fail "W4a: the PUT did not target the EXISTING ruleset id 4242; the gh call log was: $(cat "$W4_LOG")"

# (W4b) A ruleset on PAGE 2 is still found (F24). GitHub paginates this listing at 30 by default and it
#       INCLUDES org-inherited rulesets, so a repo governed by org rules pushes ours off page one. Read
#       as a single page, "absent from page 1" silently becomes "not installed" and the idempotent PUT
#       turns into a POST that creates a DUPLICATE over a live ruleset.
#       Red-when-broken: drop the pagination loop (read one page) and this case reports 'created'.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_RULESETS_PAGES=1 STUB_EXISTING_RULESET_ID=8181 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  || fail "W4b: apply failed while walking a paginated rulesets listing; got: $out"
printf '%s\n' "$out" | grep -qiE '^OK: ruleset .* updated' \
  || fail "W4b: a ruleset listed on PAGE 2 was read as absent, so the idempotent update became a duplicate CREATE (F24); got: $out"

# (W4c) WRONG-SHAPE gh bodies REFUSE rather than traceback (F16). `_gh_json` guarantees the body is
#       valid JSON — it guarantees nothing about its STRUCTURE — yet consumers indexed it directly
#       (`match["id"]`) or called `.get` on whatever came back. The module header promises "any gh
#       failure, non-JSON body, OR MISSING FIELD refuses", and a `KeyError: 'id'` is precisely that
#       missing field arriving as a traceback instead. All of these already exited non-zero before the
#       mutation, so nothing false-certified — the defect is the broken refusal CONTRACT.
#       Red-when-broken: restore `match["id"]` / drop an isinstance guard and the matching case prints
#       a Python traceback.
#       Each case PINS the refusal it is meant to produce, not a bare `^REFUSE:`. Every other gate in
#       this module also refuses, so a generic assertion passes when the case never reaches the shape
#       guard at all — which is exactly what happened once the page walk stopped ending on a SHORT
#       page: the no-id mode answered the same one-entry body for every page, so the run refused at
#       the walker's page CEILING and this case stayed green having proven nothing.
w4c() {  # $1=label  $2=text the refusal MUST contain  $3..=VAR=VAL env assignments
  local label="$1" want="$2"; shift 2
  local rc
  out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" env "$@" \
          python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)"
  rc=$?
  printf '%s\n' "$out" | grep -qi 'traceback' \
    && fail "W4c ($label): a wrong-SHAPE gh body produced a TRACEBACK instead of this module's REFUSE convention (F16); got: $out"
  [ "$rc" = "0" ] \
    && fail "W4c ($label): apply SUCCEEDED on a wrong-shape gh body; got: $out"
  printf '%s\n' "$out" | grep -qiE '^REFUSE:' \
    || fail "W4c ($label): expected a REFUSE line; got: $out"
  printf '%s\n' "$out" | grep -Fq "$want" \
    || fail "W4c ($label): the run refused, but NOT on the wrong-shape body it is meant to catch (expected text: '$want') — some earlier gate refused instead, so this case proves nothing; got: $out"
}
w4c "listing entry with no 'id'"      "carries no 'id'"                    STUB_RULESET_NO_ID=1
w4c "listing is an object, not array" "not the documented JSON array"      STUB_RULESET_DICT=1
w4c "branch.commit is a string"       "reported no tip commit"             STUB_BRANCH_BAD_SHAPE=1

# (W4d) A NULL/EMPTY listing body must REFUSE, not read as "nothing is installed" (F34). `_gh_json`
#       decodes an empty stdout as `None`, and the walk used to `break` on it — so a `gh` that exited 0
#       with no body ended the listing, `_existing_ruleset_id` returned None, and `--apply` POSTed a
#       CREATE off a read it could never verify, duplicating a ruleset that may already be live. The
#       adjacent line refuses a `{}` body with "refusing to read an unparseable listing as an empty
#       one"; `None` is not a list either. This is the MUTATION door, so the assertion is not merely
#       "it refused" but "it made NO mutation call at all".
#       Red-when-broken: restore `if body is None: break` and this case reports 'created' and logs a POST.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_RULESETS_NULL=1 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  && fail "W4d: apply MUTATED on an unverifiable (empty-body) rulesets listing — an unreadable listing is not proof that no ruleset is installed (F34); got: $out"
printf '%s\n' "$out" | grep -qi 'traceback' \
  && fail "W4d: an empty listing body produced a TRACEBACK instead of this module's REFUSE convention; got: $out"
printf '%s\n' "$out" | grep -qiE '^REFUSE:.*(empty body|unparseable listing)' \
  || fail "W4d: the refusal must name the unreadable listing, not a downstream symptom; got: $out"
W4D_LOG="$WORK/w4d-null.log"; : > "$W4D_LOG"
PATH="$STUB_BIN:$PATH" STUB_LOG="$W4D_LOG" STUB_BRANCH_SHA="$SHA_USER" STUB_RULESETS_NULL=1 \
  python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply >/dev/null 2>&1
grep -Fq -- "--method" "$W4D_LOG" \
  && fail "W4d: a mutation call was made after an unverifiable listing read; the gh call log was: $(cat "$W4D_LOG")"

# (W4e) The walk must NOT trust the server to honor `per_page` (F36). It used to stop on a SHORT page
#       (`len(body) < per_page`), which reads "the server gave me fewer than I asked for" as "that was
#       the last page". A backend serving its documented 30-item DEFAULT ends the walk after page one —
#       silently reinstating the exact F24 truncation this function exists to close, with our ruleset
#       sitting unread on page 2. Only an EMPTY page ends the walk now.
#       Red-when-broken: restore `if len(body) < per_page: break` and this case reports 'created'
#       (a DUPLICATE) instead of 'updated'.
out="$(PATH="$STUB_BIN:$PATH" STUB_BRANCH_SHA="$SHA_USER" STUB_RULESETS_SHORT=1 STUB_EXISTING_RULESET_ID=8282 \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$TGT_USER" --apply 2>&1)" \
  || fail "W4e: apply failed against a backend serving 30-item pages; got: $out"
printf '%s\n' "$out" | grep -qiE '^OK: ruleset .* updated' \
  || fail "W4e: a backend ignoring per_page truncated the listing at page one, so an installed ruleset was read as ABSENT and the idempotent update became a duplicate CREATE (F36); got: $out"

# (W4f) A listing that NEVER returns an empty page must RAISE at a page ceiling, not loop forever
#       (F36). `while True:` with no bound is not hypothetical here: the prototype stub for W4b served
#       a full page one for every page and the walker had to be KILLED rather than debugged from a
#       failure. Asserted directly on the walker so the ceiling is exercised without driving 100 full
#       `--apply` runs. `per_page=2` is NOT about cost — the stub ignores per_page and serves a
#       100-entry page regardless; it is what makes the literal 100 in the refusal unambiguously the
#       PAGE CEILING rather than the page size, so a message naming the wrong bound cannot pass.
#       The stub stops serving past page 150 (well beyond the ceiling) and ERRORS: removing the ceiling
#       makes this case fail on THAT message instead of hanging the lane.
#       HARD per-case alarm (F44). The stub's own "stop past page 150" safeguard keys on the REQUESTED
#       `page` parameter, so it only bounds a walker that is still INCREMENTING. If `page += 1` in
#       `_gh_json_all_pages` regresses, every request is page 1: the stub never reaches 150, the
#       walker never reaches its own ceiling, and this case HANGS THE LANE instead of redding — and a
#       hang reads as a slow pass, not as a failure. The alarm converts that into rc=142, which the
#       `|| fail` below turns into a red case at a bounded 20s.
PATH="$STUB_BIN:$PATH" STUB_RULESETS_ENDLESS=1 \
  perl -e 'alarm shift @ARGV; exec @ARGV' 20 python3 - "$PLUGIN/scripts" "$REPO" <<'PY' \
  || fail "W4f: the page walk did not refuse a listing that never terminates (F36)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_ruleset_install as INS

try:
    items = INS._gh_json_all_pages("repos/{}/rulesets".format(sys.argv[2]), per_page=2)
except RuntimeError as exc:
    msg = str(exc)
    if "empty page" not in msg or str(INS._MAX_LISTING_PAGES) not in msg:
        print("WRONG-REFUSAL: the walk refused, but not at the page ceiling — got: %s" % msg)
        sys.exit(1)
    print("W4f ok: refused after %d pages — %s" % (INS._MAX_LISTING_PAGES, msg))
    sys.exit(0)
print("NO-CEILING: an endless listing returned %d items instead of refusing" % len(items))
sys.exit(1)
PY
w4c "permission body is an array"     "documented permission object"        STUB_PRINCIPAL_BAD_SHAPE=1

# --- W5: the object store behind `git show` must itself verify (F13) --------------------------------
#
# `_git` disables replacement REFS, which closes the `refs/replace/*` rewiring in W3f. It does NOT make
# `git show` trustworthy, because git does not verify an object's hash when it READS one: overwriting
# the loose object file for the committed blob returns attacker bytes while `rev-parse` still reports
# the ORIGINAL commit and blob oids. Every other gate is then satisfied BY CONSTRUCTION — the commit oid
# is untouched so the tip check matches GitHub, and the working tree is left holding the same substituted
# bytes so the divergence gate passes. Measured: `GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects show`
# returns the substituted bytes too, so the W3f hardening provably does not reach this layer.
#
# Red-when-broken: delete the `_object_chain_problem` call in `main()` and BOTH cases below print
# `OK: ruleset ... created` over a repo binding one of seven surfaces.

# Build a checkout whose ENFORCED CODEOWNERS covers exactly ONE surface (so it MUST be refused), then
# substitute wide content underneath it at the object layer. $1=dir, $2=variant (blob|tree)
mk_object_tamper() {
  local dir="$1" variant="$2"
  mk_target "$dir" "@alice"
  cat > "$dir/.github/CODEOWNERS" <<'CO'
/.github/CODEOWNERS @alice
CO
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "narrow codeowners (the bytes GitHub enforces)"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  # The working tree is left holding the WIDE content, so with the guard removed the divergence gate
  # sees wide == wide and passes — making this a genuine false-certify rather than a lucky save.
  cat > "$dir/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @alice
/scripts/hooks/ @alice
/scripts/idc_validation_contract.py @alice
/scripts/idc_receipt_check.py @alice
/scripts/idc_pathway_check.py @alice
/scripts/idc_ruleset_check.py @alice
/scripts/idc_path_gate.py @alice
/scripts/idc_git_path_gate.py @alice
/scripts/idc_build_receipt.py @alice
/.github/rulesets/ @alice
/.github/CODEOWNERS @alice
CO
  python3 - "$dir" "$variant" <<'PY'
import binascii, os, subprocess, sys, zlib
root, variant = sys.argv[1], sys.argv[2]
wide = open(os.path.join(root, ".github", "CODEOWNERS"), "rb").read()

def git(*a):
    return subprocess.run(["git", "-C", root] + list(a), capture_output=True, text=True).stdout.strip()

def overwrite(oid, kind, body):
    store = kind + b" " + str(len(body)).encode() + b"\x00" + body
    p = os.path.join(root, ".git", "objects", oid[:2], oid[2:])
    os.chmod(p, 0o644)
    with open(p, "wb") as fh:
        fh.write(zlib.compress(store))

if variant == "blob":
    # Substitute the committed blob's own object file with the wide bytes. The blob oid is UNCHANGED.
    overwrite(git("rev-parse", "HEAD:.github/CODEOWNERS"), b"blob", wide)
else:
    # Harder variant: legitimately write the wide blob, then rewrite the enclosing `.github` TREE to
    # point at it. `git rev-parse HEAD:.github/CODEOWNERS` then reports the ATTACKER's blob oid, which
    # re-hashes to itself — so re-hashing `git show` output against the reported oid is self-consistent
    # and does NOT catch this. Only re-hashing the chain does.
    newb = subprocess.run(["git", "-C", root, "hash-object", "-w", "--stdin"],
                          input=wide, capture_output=True).stdout.decode().strip()
    overwrite(git("rev-parse", "HEAD:.github"), b"tree",
              b"100644 CODEOWNERS\x00" + binascii.unhexlify(newb))
PY
}

for variant in blob tree; do
  TGT_OBJ="$WORK/tgt-object-$variant"
  mk_object_tamper "$TGT_OBJ" "$variant"
  SHA_OBJ="$(git -C "$TGT_OBJ" rev-parse HEAD)"
  # Prove the fixture is REAL before asserting on it: `git show` must hand back the WIDE bytes while the
  # commit oid is unchanged, and the W3f hardening must NOT save us. A fixture that does not diverge
  # would make the assertion below pass for the wrong reason.
  GIT_NO_REPLACE_OBJECTS=1 git -C "$TGT_OBJ" --no-replace-objects show "$SHA_OBJ:.github/CODEOWNERS" 2>/dev/null | grep -Fq '/scripts/hooks/' \
    || fail "W5 fixture ($variant): \`git show\` did not return the substituted wide bytes even with replace-objects disabled — the object tamper is not set up, so this case cannot prove the guard works"
  out="$(apply "$TGT_OBJ" "$SHA_OBJ")" \
    && fail "W5 ($variant): apply CERTIFIED through an OBJECT-STORE tamper — it validated attacker-chosen CODEOWNERS while every oid, the live tip check and the divergence gate all agreed; got: $out"
  printf '%s\n' "$out" | grep -qiE '^OK: ruleset' \
    && fail "W5 ($variant): apply reported the ruleset was created over a repo whose ENFORCED CODEOWNERS binds one surface; got: $out"
  printf '%s\n' "$out" | grep -qiE 'object store|fsck' \
    || fail "W5 ($variant): the refusal must name the failed OBJECT-STORE verification, not a downstream symptom; got: $out"
done

# (W5c) CONTROL — an untampered checkout still passes the chain verification, so the gate is a real
#       check and not a blanket refusal of every repository.
out="$(apply "$TGT_USER" "$SHA_USER")" \
  || fail "W5c: the object-chain gate REFUSED a healthy checkout; got: $out"
printf '%s\n' "$out" | grep -qiE 'object store|fsck' \
  && fail "W5c: a healthy checkout was reported as failing object verification; got: $out"

# (W5d) The gate covers DRY-RUN too, not just --apply. Dry-run prints a plan that reads as a green
#       assessment of the target's ownership, so a tampered store must refuse there as well — and it
#       must do so WITHOUT a network call, since `git fsck` is purely local.
DRY_OBJ_LOG="$WORK/dry-run-object-tamper.log"; : > "$DRY_OBJ_LOG"
out="$(PATH="$STUB_BIN:$PATH" STUB_LOG="$DRY_OBJ_LOG" \
        python3 "$INS" --ruleset "$RS" --repo "$REPO" --repo-root "$WORK/tgt-object-blob" 2>&1)" \
  && fail "W5d: DRY-RUN printed a plan over a tampered object store; got: $out"
printf '%s\n' "$out" | grep -qiE 'object store|fsck' \
  || fail "W5d: the dry-run refusal must name the failed object-store verification; got: $out"
if [ -s "$DRY_OBJ_LOG" ]; then
  echo "--- gh calls made during the dry-run object-tamper case:"; cat "$DRY_OBJ_LOG"
  fail "W5d: the object-chain gate made a NETWORK call — \`git fsck\` is local, and dry-run must stay local-only"
fi

# --- W6: the production denylist is case-insensitive (F31) ------------------------------------------
# GitHub owner/repo names are case-insensitive, so `LlamaLlamaRedPajama/IDC-Workflow` IS the protected
# production repo. An exact `in PROTECTED_REPOS` match walked a differently-cased spelling straight past
# the denylist into the live apply path. Exit 3 is the denylist's own code, and it refuses BEFORE any
# network call — so the stub log must stay empty too.
W6_LOG="$WORK/w6-denylist.log"; : > "$W6_LOG"
PATH="$STUB_BIN:$PATH" STUB_LOG="$W6_LOG" \
  python3 "$INS" --ruleset "$RS" --repo "LlamaLlamaRedPajama/IDC-Workflow" \
    --repo-root "$TGT_USER" --apply >"$WORK/w6.out" 2>&1
rc=$?
[ "$rc" = "3" ] \
  || fail "W6: a MIXED-CASE spelling of a protected production repo exited $rc, not the denylist's 3 — GitHub repo names are case-insensitive, so this is the same repository (F31); got: $(cat "$WORK/w6.out")"
grep -qi 'protected production repository' "$WORK/w6.out" \
  || fail "W6: the refusal must be the production denylist's; got: $(cat "$WORK/w6.out")"
[ -s "$W6_LOG" ] \
  && fail "W6: the denylist refused only AFTER a network call; it must refuse before any gh call. Log: $(cat "$W6_LOG")"
# Control: the exact-case spelling is refused identically, so W6 is about CASE and not about the name.
PATH="$STUB_BIN:$PATH" python3 "$INS" --ruleset "$RS" --repo "llamallamaredpajama/idc-workflow" \
  --repo-root "$TGT_USER" --apply >/dev/null 2>&1
[ "$?" = "3" ] || fail "W6 control: the exact-case protected repo was not refused with exit 3"

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

echo "PASS: the installer's --apply path binds certification to the live repository (W2+W3) — the validation ref must NAME GitHub's live default branch (a stale origin/HEAD, a non-default override, and a raw SHA are all refused; both \`D\` and \`origin/D\` spellings pass) and the local checkout must be at the same tip; every CODEOWNERS owner principal must resolve with write-or-better access (missing/read-only user, missing/read-only team, an email owner, a gh failure, and a non-JSON body each refuse fail-closed), with maintain/admin accepted, a body omitting the legacy \`permission\` field decided on GitHub's BOOLEAN capability map (GHE compatibility) and REFUSED when it carries neither that map nor a \`permission\` field, so a free-form custom role name can neither out-vote an authoritative 'read' nor stand in as proof of access on its own (NEW-12); wrong-SHAPE gh bodies REFUSE instead of raising KeyError/AttributeError (F16); the rulesets listing is PAGINATED, so a ruleset on page 2 is updated rather than duplicated (F24), and an already-installed ruleset takes the PUT/update branch (F23); that page walk REFUSES rather than mutating on anything short of a complete listing — a null/empty body is not proof of absence and makes ZERO mutation calls (F34), a backend ignoring per_page cannot truncate it into a duplicate CREATE, and a listing that never empties is refused at a page ceiling instead of looping forever (F36); the git OBJECT STORE behind \`git show\` is itself verified with \`git fsck\` before anything is certified, so substituting the committed blob's object file — or the enclosing tree, which self-consistently re-hashes — is REFUSED in apply AND dry-run while a healthy checkout still passes (F13); the production denylist matches CASE-INSENSITIVELY before any network call (F31); and dry-run still makes ZERO gh calls"
