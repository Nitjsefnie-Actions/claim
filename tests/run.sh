#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(mktemp -d "$ROOT/tests/.run.XXXXXX")"
mkdir "$RUN/bin"
ln -s "$ROOT/tests/gh.sh" "$RUN/bin/gh"
export PATH="$RUN/bin:$PATH"
export GH_TOKEN=test-token REPO=owner/project ISSUE=7 ACTOR=actor ACTOR_TYPE=User
export GH_CASE

expect_gh() {
  local response=$1
  shift
  jq -cn --args '$ARGS.positional' -- "$@" >> "$GH_CASE/expected.jsonl"
  printf '%s' "$response" > "$GH_CASE/response.$(wc -l < "$GH_CASE/expected.jsonl")"
}

run_claim() {
  local expected_status=$1 expected_output=${2-} status=0 failed=0
  BODY="$body" "$ROOT/claim.sh" > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
  if [[ $status != "$expected_status" ]]; then
    printf '  exit status: expected %s, got %s\n' "$expected_status" "$status"
    failed=1
  fi
  printf '%s' "$expected_output" > "$GH_CASE/expected.stdout"
  if ! diff -u "$GH_CASE/expected.stdout" "$GH_CASE/stdout"; then failed=1; fi
  if ! diff -u "$GH_CASE/expected.jsonl" "$GH_CASE/calls.jsonl"; then failed=1; fi
  if [[ -s $GH_CASE/stderr ]]; then cat "$GH_CASE/stderr"; failed=1; fi
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
  expect_gh '{"state":"open","assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@actor you already have this one.' --silent
  run_claim 0
}

trimmed_command() {
  body=$' \t/claim \t\r'
  expect_gh '{"state":"open","assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@actor you already have this one.' --silent
  run_claim 0
}

blank_lines_around_command() {
  body=$'\n \t\r\n/claim\n \t\r\n'
  expect_gh '{"state":"open","assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@actor you already have this one.' --silent
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
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=actor' --silent
  expect_gh '{"state":"open","assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @actor.' --silent
  run_claim 0
}

claim_rejected() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=actor' --silent
  expect_gh '{"state":"open","assignees":[{"login":"someone-else"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=GitHub would not accept @actor as an assignee here. That usually means the account needs to have commented on or been granted access to this repository.' --silent
  run_claim 1
}

unclaim_not_assigned() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@actor you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

unclaim_one_of_two() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=actor' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Unassigned @actor.' --silent
  run_claim 0
}

release_one_of_two() {
  body=/release
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"actor"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=actor' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Unassigned @actor.' --silent
  run_claim 0
}

closed_issue() {
  body=/claim
  expect_gh '{"state":"closed","assignees":[]}' api repos/owner/project/issues/7
  run_claim 0
}

pull_request() {
  body=/unclaim
  expect_gh '{"state":"open","pull_request":{"url":"https://api.github.com/repos/owner/project/pulls/7"},"assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  run_claim 0
}

bot_actor() {
  body=/release
  ACTOR_TYPE=Bot
  expect_gh '{"state":"open","assignees":[{"login":"actor"}]}' api repos/owner/project/issues/7
  run_claim 0
}

cases=(sentence multiline metacharacters already_assigned trimmed_command
  blank_lines_around_command whitespace_only claimed_by_others claimed_by_three claim_accepted
  claim_rejected unclaim_not_assigned unclaim_one_of_two release_one_of_two
  closed_issue pull_request bot_actor)
failures=0
for case_name in "${cases[@]}"; do
  GH_CASE="$RUN/$case_name"
  mkdir "$GH_CASE"
  : > "$GH_CASE/expected.jsonl"
  : > "$GH_CASE/calls.jsonl"
  ACTOR_TYPE=User
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
