#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(mktemp -d "$ROOT/tests/.run.XXXXXX")"
mkdir "$RUN/bin"
ln -s "$ROOT/tests/gh.sh" "$RUN/bin/gh"
export PATH="$RUN/bin:$PATH"
export GH_TOKEN REPO ISSUE ACTOR ACTOR_TYPE GH_CASE

reset_case() {
  GH_TOKEN=test-token
  REPO=owner/project
  ISSUE=7
  ACTOR=octo-claimant
  ACTOR_TYPE=User
  body=
  expected_error=
}

expect_gh() {
  local response=$1
  shift
  jq -cn --args '$ARGS.positional' -- "$@" >> "$GH_CASE/expected.jsonl"
  printf '%s' "$response" > "$GH_CASE/response.$(wc -l < "$GH_CASE/expected.jsonl" | tr -d '[:space:]')"
}

expect_gh_failure() {
  local status=$1 error=$2 ordinal
  shift 2
  expect_gh '' "$@"
  ordinal=$(wc -l < "$GH_CASE/expected.jsonl" | tr -d '[:space:]')
  printf '%s' "$status" > "$GH_CASE/response.$ordinal.status"
  printf '%s\n' "$error" > "$GH_CASE/response.$ordinal.stderr"
}

run_claim() {
  local expected_status=$1 expected_output=${2-} status=0 failed=0
  BODY="$body" "$ROOT/claim.sh" > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
  if [[ $expected_status == nonzero && $status == 0 ]] ||
     [[ $expected_status != nonzero && $status != "$expected_status" ]]; then
    printf '  exit status: expected %s, got %s\n' "$expected_status" "$status"
    failed=1
  fi
  printf '%s' "$expected_output" > "$GH_CASE/expected.stdout"
  if ! diff -u "$GH_CASE/expected.stdout" "$GH_CASE/stdout"; then failed=1; fi
  if ! diff -u "$GH_CASE/expected.jsonl" "$GH_CASE/calls.jsonl"; then failed=1; fi
  if [[ -n $expected_error ]]; then
    if ! grep -Eq -- "$expected_error" "$GH_CASE/stderr"; then
      printf '  expected stderr matching: %s\n' "$expected_error"
      cat "$GH_CASE/stderr"
      failed=1
    fi
  elif [[ -s $GH_CASE/stderr ]]; then
    cat "$GH_CASE/stderr"
    failed=1
  fi
  return "$failed"
}

sentence() {
  body='please /claim this when you can'
  run_claim 0 $'not a command: please /claim this when you can\n'
}

multiline() {
  body=$'/claim\nthis is a second line'
  run_claim 0 $'not a command: /claim\n'
}

interior_cr() {
  body=$'hello there\r\nsecond line'
  run_claim 0 $'not a command: hello there\n'
}

metacharacters() {
  local result=0
  # The literal shell syntax must reach the child unchanged, including both quotes.
  # shellcheck disable=SC2016
  body='$(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'
  body+=$'\nsecond line'
  (cd "$GH_CASE" && run_claim 0 $'not a command: $(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'$'\n') || result=$?
  if [[ -e $GH_CASE/pwned || -e $GH_CASE/backtick-pwned || -e /tmp/pwned ]]; then
    printf '  comment body executed a shell side effect\n'
    result=1
  fi
  return "$result"
}

already_assigned() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

trimmed_command() {
  body=$' \t/claim \t\r'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

blank_lines_around_command() {
  body=$'\n \t\r\n/claim\n \t\r\n'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

whitespace_only() {
  body=$' \t\r\n '
  run_claim 0 $'not a command: \n'
}

claimed_by_others() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claimed_by_three() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"},{"login":"carol"}]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob, @carol. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claim_accepted() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

claim_accepted_elsewhere() {
  body=/claim
  ACTOR=river-helper
  REPO=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api -X POST repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper' --silent
  expect_gh '{"state":"open","assignees":[{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments -f 'body=Assigned to @river-helper.' --silent
  run_claim 0
}

claim_rejected() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '{"state":"open","assignees":[{"login":"someone-else"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=GitHub would not accept @octo-claimant as an assignee here. That usually means the account needs to have commented on or been granted access to this repository.' --silent
  run_claim 1
}

assignment_post_forbidden() {
  body=/claim
  expected_error='HTTP 403'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  run_claim nonzero
}

unclaim_delete_forbidden() {
  body=/unclaim
  expected_error='HTTP 403'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  run_claim nonzero
}

comment_forbidden() {
  body=/claim
  expected_error='HTTP 403'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim nonzero
}

unclaim_not_assigned() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

unclaim_one_of_two() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Unassigned @octo-claimant.' --silent
  run_claim 0
}

release_one_of_two() {
  body=/release
  ACTOR=river-helper
  REPO=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api -X DELETE repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper' --silent
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments -f 'body=Unassigned @river-helper.' --silent
  run_claim 0
}

closed_issue() {
  body=/claim
  expect_gh '{"state":"closed","assignees":[]}' api repos/owner/project/issues/7
  run_claim 0
}

malformed_snapshot() {
  body=/claim
  expected_error='parse error'
  expect_gh '{"state":"open",' api repos/owner/project/issues/7
  run_claim nonzero
}

missing_assignees() {
  body=/claim
  expected_error='assignees array'
  expect_gh '{"state":"open"}' api repos/owner/project/issues/7
  run_claim nonzero
}

pull_request() {
  body=/unclaim
  expect_gh '{"state":"open","pull_request":{"url":"https://api.github.com/repos/owner/project/pulls/7"},"assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  run_claim 0
}

bot_actor() {
  body=/release
  ACTOR_TYPE=Bot
  run_claim 0
}

organization_actor() {
  body=/claim
  ACTOR_TYPE=Organization
  run_claim 0
}

mannequin_actor() {
  body=/claim
  ACTOR_TYPE=Mannequin
  run_claim 0
}

invalid_issue() {
  body=/claim
  ISSUE='7/comments?x=1'
  expected_error='invalid issue: expected digits'
  run_claim nonzero
}

invalid_repository() {
  body=/claim
  REPO='owner/project/issues'
  expected_error='invalid repository: expected owner/name'
  run_claim nonzero
}

repository_query() {
  body=/claim
  REPO='owner/project?x=1'
  expected_error='invalid repository: expected owner/name'
  run_claim nonzero
}

cases=(sentence multiline interior_cr metacharacters already_assigned trimmed_command
  blank_lines_around_command whitespace_only claimed_by_others claimed_by_three claim_accepted
  claim_accepted_elsewhere claim_rejected unclaim_not_assigned unclaim_one_of_two release_one_of_two
  closed_issue malformed_snapshot missing_assignees pull_request bot_actor
  organization_actor mannequin_actor invalid_issue invalid_repository repository_query
  assignment_post_forbidden unclaim_delete_forbidden comment_forbidden)
failures=0
for case_name in "${cases[@]}"; do
  GH_CASE="$RUN/$case_name"
  mkdir "$GH_CASE"
  : > "$GH_CASE/expected.jsonl"
  : > "$GH_CASE/calls.jsonl"
  reset_case
  if "$case_name"; then
    printf 'PASS %s\n' "$case_name"
  else
    printf 'FAIL %s\n' "$case_name"
    failures=$((failures + 1))
  fi
done
printf '%s cases, %s failures\n' "${#cases[@]}" "$failures"
if (( failures )); then
  printf 'Artifacts: %s\n' "$RUN"
  exit 1
fi
rm -r -- "$RUN"
