#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(mktemp -d "$ROOT/tests/.run.XXXXXX")"
mkdir "$RUN/bin"
ln -s "$ROOT/tests/gh.sh" "$RUN/bin/gh"
export PATH="$RUN/bin:$PATH"
# GH_IDENTITY is the default answer for the stub's identity lookup
# (`gh api user`); a case overrides it by writing identity.response into its
# own case directory. The value is per-case state, set in reset_case below.
export GH_TOKEN REPOSITORY ISSUE ACTOR ACTOR_TYPE GH_CASE GH_IDENTITY

reset_case() {
  GH_TOKEN=test-token
  REPOSITORY=owner/project
  ISSUE=7
  ACTOR=octo-claimant
  ACTOR_TYPE=User
  GH_IDENTITY=$ROOT/tests/identity.response
  body=
  expected_error=
}

expect_gh() {
  local response=$1 ordinal
  shift
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], separators=(",", ":")))' "$@" >> "$GH_CASE/expected.jsonl"
  ordinal=$(wc -l < "$GH_CASE/expected.jsonl")
  printf '%s' "$response" > "$GH_CASE/response.$((ordinal))"
}

expect_gh_failure() {
  local status=$1 error=$2 ordinal
  shift 2
  expect_gh '' "$@"
  ordinal=$(wc -l < "$GH_CASE/expected.jsonl")
  ordinal=$((ordinal))
  printf '%s' "$status" > "$GH_CASE/response.$ordinal.status"
  printf '%s\n' "$error" > "$GH_CASE/response.$ordinal.stderr"
}

# expected.jsonl describes the calls that ACT: the identity lookup is answered
# from its own fixture outside that sequence, so its record is set aside before
# the diff. A case that must pin the identity call itself reads calls.jsonl.
ordinary_calls() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as recorded:
    for line in recorded:
        if json.loads(line) != ["api", "user"]:
            sys.stdout.write(line)
' "$1"
}

run_claim() {
  local expected_status=$1 expected_output=${2-} status=0 failed=0
  BODY="$body" python3 "$ROOT/claim.py" > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
  if [[ $status != "$expected_status" ]]; then
    printf '  exit status: expected %s, got %s\n' "$expected_status" "$status"
    failed=1
  fi
  printf '%s' "$expected_output" > "$GH_CASE/expected.stdout"
  if ! diff -u "$GH_CASE/expected.stdout" "$GH_CASE/stdout"; then failed=1; fi
  if ! diff -u "$GH_CASE/expected.jsonl" <(ordinary_calls "$GH_CASE/calls.jsonl"); then failed=1; fi
  if [[ -n $expected_error ]]; then
    printf '%s\n' "$expected_error" > "$GH_CASE/expected.stderr"
  else
    : > "$GH_CASE/expected.stderr"
  fi
  if ! diff -u "$GH_CASE/expected.stderr" "$GH_CASE/stderr"; then failed=1; fi
  if grep -Fq 'Traceback' "$GH_CASE/stderr"; then
    printf '  unexpected traceback\n'
    failed=1
  fi
  return "$failed"
}

# The character count of the comment body the last recorded call posted: the
# reply as it went out, not as the case expected it to. A call that posted no
# body has no length, so this prints `unmeasured` — a word, not a number, so
# the caller cannot compare or count it by accident and pass.
posted_comment_length() {
  python3 -c '
import json, sys
body = None
for line in open(sys.argv[1]):
    for arg in json.loads(line):
        if arg.startswith("body="):
            body = arg[len("body="):]
print(len(body) if body is not None else "unmeasured")
' "$GH_CASE/calls.jsonl"
}

sentence() {
  body='please /claim this when you can'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `please /claim this when you can`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: please /claim this when you can\n'
}

multiline() {
  body=$'/claim\nthis is a second line'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim\n'
}

interior_cr() {
  body=$'hello there\r\nsecond line'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `hello there`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: hello there\n'
}

metacharacters() {
  local result=0
  # The literal shell syntax must reach the child unchanged, including both quotes.
  # shellcheck disable=SC2016
  body='$(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'
  body+=$'\nsecond line'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments \
    --input - 'body=Not a command: `$(touch /tmp/pwned) $(touch pwned) \`touch backtick-pwned\` '\''single'\'' "double"`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' \
    --silent
  (cd "$GH_CASE" && run_claim 1 $'not a command: $(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'$'\n') || result=$?
  if [[ -e $GH_CASE/pwned || -e $GH_CASE/backtick-pwned || -e /tmp/pwned ]]; then
    printf '  comment body executed a shell side effect\n'
    result=1
  fi
  return "$result"
}

already_assigned() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

trimmed_command() {
  body=$' \t/claim \t\r'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

blank_lines_around_command() {
  body=$'\n \t\r\n/claim\n \t\r\n'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

whitespace_only() {
  body=$' \t\r\n '
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: ``. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: \n'
}

claimed_by_others() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claimed_by_three() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"},{"login":"carol"}]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob, @carol. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claim_accepted() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# Two claims that both read an empty assignee list. The winner is the one the
# issue's events record as assigned FIRST, which here is yuki-dev even though
# alice sorts before it: the assignee list carries no order, so a sort over it
# would have picked the wrong login. The "labeled" event pins that an event of
# any other type is ignored even though it names no assignee. The events'
# actor is the suite default identity fixture's login — renamed from the old
# generic claim-bot — so this case also pins that a user-token settle still
# settles once the rule requires the action's own identity (#58
# anti-regression).
contested_winner_by_event_order() {
  body=/claim
  ACTOR=yuki-dev
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"yuki-dev"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=yuki-dev'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"yuki-dev"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"yuki-dev"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}},{"id":950,"event":"labeled","actor":{"login":"claim-token-account"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @yuki-dev. @alice was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

# The straggler ordering: alice's run finishes second and finds zoe-helper
# already assigned, and alice sorts first of the two. It removes its OWN login
# and says who holds the issue — the interleaving no rule over the assignee list
# alone can express.
contested_loser_by_event_order() {
  body=/claim
  ACTOR=alice
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zoe-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=alice'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zoe-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zoe-helper"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=You and @zoe-helper claimed this issue at the same time, and @zoe-helper holds it, so your claim was released.' --silent
  run_claim 0
}

# Two events sharing an id: the order is (id, login), so the loser is still
# removed. Reading "everyone with a LARGER id" leaves the pair behind and the
# run answers Assigned to @octo-claimant on an issue held by two.
contested_equal_event_ids() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

# The reviewer's replay: the unassigned event spells the login with different
# case from the assigned event AND from the confirming snapshot. GitHub treats
# logins case-insensitively, so the unassign is the same signal and clears the
# map — which leaves Zara-Helper with no current event, so the run bails and
# deletes nothing. Matching case-sensitively would keep the stale assigned, crown
# the removed login winner on its stale id, and DELETE octo-claimant, a live
# claim, on the one path where everything else bails.
unassigned_login_spelling_clears_map() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"Zara-Helper"},{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"Zara-Helper"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"Zara-Helper"}},{"id":800,"event":"unassigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @Zara-Helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The same spelling question where the differently-cased event is the one that
# decides: octo-claimant holds id 700 and Zara-Helper's current assignment is
# the id 800 event spelled in the other case. octo-claimant wins and the DELETE
# names "Zara-Helper" — the spelling the ISSUE payload returned, not the one the
# event used. Matching case-sensitively drops the 800, leaves the stale 600
# assigned, and deletes octo-claimant instead.
assigned_login_spelling_decides() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"Zara-Helper"},{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"Zara-Helper"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":600,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"Zara-Helper"}},{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=Zara-Helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant. @Zara-Helper was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

# zara-helper was assigned, unassigned and reassigned inside the window, and its
# FIRST event has the smallest id of all. The event that decides is the current
# one, so yuki-dev wins; reading the earliest assignment per login would have
# made zara-helper the winner and deleted yuki-dev instead.
contested_assign_cycle_decides_current_event() {
  body=/claim
  ACTOR=yuki-dev
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"yuki-dev"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=yuki-dev'
  expect_gh '{"state":"open","assignees":[{"login":"yuki-dev"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":100,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":200,"event":"unassigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":250,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"yuki-dev"}},{"id":300,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @yuki-dev. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

# A third identity in the window: two of the assignments are this action's own
# and one is a maintainer's. Nothing is deleted — not the rival claim, not this
# run's own login — and the run says so. The earlier design settled this by
# having every claimant delete itself, which emptied the issue and left each
# commenter told the other held it.
# Backticks here are Markdown in the expected comment, not shell substitutions.
# shellcheck disable=SC2016
contested_third_identity_bails() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"aaron-maintainer"},{"login":"alice"},{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"aaron-maintainer"},{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"aaron-maintainer"},"assignee":{"login":"aaron-maintainer"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @aaron-maintainer, @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The events page does not cover one of the confirmed logins — an event not yet
# visible, or a page the read did not follow. Nothing is changed, the run says
# so, and it fails: guessing an order here could remove a stranger's write.
# shellcheck disable=SC2016
cannot_attribute_missing_event() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The other shape of the bail: this run's own login is not among the confirmed
# assignees, and one of theirs has no readable event. Every confirmed assignee
# is named, because none of them is this runer's to exclude.
# shellcheck disable=SC2016
bail_with_actor_absent() {
  body=/claim
  ACTOR=octo-claimant
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zara-helper"},{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @alice, @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. You are not assigned to this issue.' --silent
  run_claim 1
}

# zara-helper's assignment was undone after the confirming read. Its unassigned
# event must take it out of the current map, so the run cannot crown the
# earliest id it saw and delete octo-claimant on the strength of an assignment
# that no longer exists.
# shellcheck disable=SC2016
unassigned_event_drops_from_current() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":800,"event":"unassigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# An event the parser cannot read for a login that IS assigned here: the login
# drops out of the current map and the run bails with an explanation. Raising
# here would be an outage with nothing on the issue saying why.
# shellcheck disable=SC2016
unreadable_event_field_bails() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The issue's history is unbounded, and none of it is this action's business
# unless it names somebody assigned here: a deleted account's event with a null
# assignee, and an old claim by somebody who is not on the issue now. Both are
# skipped, and the settle proceeds — validating the whole history would let one
# malformed event from years ago disable every future claim on this issue.
contested_unrelated_events_ignored() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":50,"event":"assigned","actor":{"login":"ghost-account"},"assignee":null},{"id":60,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"someone-else"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

# The other ordering of that race, and the reason the POST's own response is
# the decline discriminator: this run's POST was accepted, and a peer removed
# it before the re-read. It must be told it lost, and must write NOTHING — it
# holds nothing and has no business deleting somebody else's assignment. Its own
# unassigned event is why the token still has to be readable from the timeline.
contested_claim_loser_removed_before_read() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"alice"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":850,"event":"unassigned","actor":{"login":"alice"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=You and @alice claimed this issue at the same time, and @alice holds it, so your claim was released.' --silent
  run_claim 0
}

# Three claimants at once: every claim later than the winner's is removed, not
# only the first one the list happens to name.
contested_claim_winner_of_three() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"sana-helper"},{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"sana-helper"},{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"sana-helper"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=sana-helper' --silent
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant. @sana-helper, @zara-helper were assigned at the same time, so those assignments were removed.' --silent
  run_claim 0
}

# The loser among three: it removes its own login and the claim after it, and
# leaves the earliest event alone.
contested_claim_loser_among_three() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"sana-helper"},{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"sana-helper"},{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"sana-helper"}},{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"zara-helper"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=You and @sana-helper claimed this issue at the same time, and @sana-helper holds it, so your claim was released.' --silent
  run_claim 0
}

# A removal the token is not allowed to make fails the run before any comment,
# exactly as the /unclaim DELETE does, rather than posting a success the issue
# does not have.
contested_removal_forbidden() {
  body=/claim
  ACTOR=yuki-dev
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"yuki-dev"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=yuki-dev'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"yuki-dev"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"yuki-dev"}},{"id":900,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"alice"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  run_claim 1
}

# Every assignment the run can see is gone: its own was removed after the POST
# and no rival holds the issue either. There is nobody to name and nothing to
# settle, which must not fall through to picking a winner from an empty list.
no_assignees_left_after_peer_removals() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant nothing is assigned to this issue any more.' --silent
  run_claim 0
}

# A response the script cannot read at all aborts it, rather than settling an
# order it guessed at. Three shapes, three cases: the slurped payload is not an
# array of pages, a page is not an array, and an entry is not an event object.
malformed_events_pages() {
  body=/claim
  expected_error='issue events must be an array of pages'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open"}' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  run_claim 1
}

malformed_events_page() {
  body=/claim
  expected_error='issue events must be an array of pages'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[{"id":800,"event":"assigned","actor":{"login":"claim-token-account"},"assignee":{"login":"octo-claimant"}}]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  run_claim 1
}

malformed_events_object() {
  body=/claim
  expected_error='issue events must contain event objects'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[["not an event"]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  run_claim 1
}

claim_accepted_elsewhere() {
  body=/claim
  ACTOR=river-helper
  REPOSITORY=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[]}' api repos/other-team/widget.tools/issues/42
  expect_gh '{"state":"open","assignees":[{"login":"river-helper"}]}' api -X POST repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper'
  expect_gh '{"state":"open","assignees":[{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments --input - 'body=Assigned to @river-helper.' --silent
  run_claim 0
}

# GitHub declines the assignee: the POST's own response omits the actor, which
# is the only place a decline and a peer's removal can be told apart.
claim_rejected() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"someone-else"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=GitHub would not accept @octo-claimant as an assignee here. That usually means the account needs to have commented on or been granted access to this repository.' --silent
  run_claim 1
}

claim_with_number() {
  body='/claim 7'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

claim_with_hash_number() {
  body='/claim #7'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

unclaim_with_number() {
  body='/unclaim 7'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Unassigned @octo-claimant.' --silent
  run_claim 0
}

claim_number_mismatch() {
  body='/claim 8'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=`/claim 8` names issue 8, but this comment is on issue 7. Comment `/claim` (or `/claim 7`) to act on this issue.' --silent
  run_claim 1
}

# A carried number of N digits, for a case that needs a body whose number is
# far longer than any issue has.
digits_of() {
  local count=$1 digits
  printf -v digits '%*s' "$count" ''
  printf '%s' "${digits//' '/1}"
}

# N characters of filler, for a comment body of a length the stub has to judge.
chars_of() {
  local count=$1 text
  printf -v text '%*s' "$count" ''
  printf '%s' "${text//' '/x}"
}

# The JSON `gh api --input -` reads a comment body from, built the way
# claim.py builds it rather than by hand, so a case that drives the stub
# directly sends the transport claim.py sends.
comment_payload() {
  python3 -c 'import json, sys; print(json.dumps({"body": sys.stdin.read()}))'
}

# The ceiling's own reply, on this issue: one comment, the sentence that says
# why the real one could not be posted, and the commands to type instead.
expect_over_length_reply() {
  local issue=${1-7}
  # shellcheck disable=SC2016
  expect_gh '' api "repos/owner/project/issues/${issue}/comments" --input - \
    "body=I could not answer that here: the answer would be longer than GitHub allows in a comment (65536 characters). Comment \`/claim\`, \`/unclaim\` or \`/release\` on its own, optionally followed by the issue number, for example \`/claim ${issue}\` or \`/claim #${issue}\`." \
    --silent
}

claim_number_over_long() {
  local digits
  # 33,000 digits is the size #45 reports: unbounded, it built a
  # 66,111-character reply that GitHub refused to post, so the commenter was
  # answered with nothing at all. It must still be answered, and briefly.
  digits=$(digits_of 33000)
  body="/claim #${digits}"
  expect_over_length_reply
  run_claim 1
}

# Any carried number that fits in a reply is quoted in full, and the ceiling
# in say() is the only thing that decides where that stops: nothing here counts
# digits, so a number one digit longer is quoted exactly as one digit shorter.
claim_number_quoted_in_full() {
  local carried result=0
  carried=$(digits_of 32)
  body="/claim ${carried}"
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    "body=\`/claim ${carried}\` names issue ${carried}, but this comment is on issue 7. Comment \`/claim\` (or \`/claim 7\`) to act on this issue." \
    --silent
  run_claim 1 || result=$?
  carried=$(digits_of 33)
  body="/claim ${carried}"
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    "body=\`/claim ${carried}\` names issue ${carried}, but this comment is on issue 7. Comment \`/claim\` (or \`/claim 7\`) to act on this issue." \
    --silent
  run_claim 1 || result=$?
  return "$result"
}

# The edge of the ceiling, and the property it stands for rather than a value
# of anything: measured on the unbounded reply at the base commit, and a
# different number for every command word because the reply quotes the word
# twice. 32,712 digits is the most `/claim` could carry and still be posted,
# at 65,535 characters; 32,713 gives 65,537 and was refused. `/release` is two
# characters longer, so it crosses two digits earlier: 32,709 fits at 65,535
# and 32,710 does not. All four have to be answered, and the two that fit have
# to be answered whole — a ceiling set above that point re-opens the defect
# these numbers came from, and these two samples catch it on the length rather
# than incidentally on the reply's text.
claim_number_ceiling_edge() {
  local carried result=0
  carried=$(digits_of 32712)
  body="/claim #${carried}"
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    "body=\`/claim #${carried}\` names issue ${carried}, but this comment is on issue 7. Comment \`/claim\` (or \`/claim 7\`) to act on this issue." \
    --silent
  run_claim 1 || result=$?
  carried=$(digits_of 32713)
  body="/claim #${carried}"
  expect_over_length_reply
  run_claim 1 || result=$?
  carried=$(digits_of 32709)
  body="/release #${carried}"
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    "body=\`/release #${carried}\` names issue ${carried}, but this comment is on issue 7. Comment \`/release\` (or \`/release 7\`) to act on this issue." \
    --silent
  run_claim 1 || result=$?
  carried=$(digits_of 32710)
  body="/release #${carried}"
  expect_over_length_reply
  run_claim 1 || result=$?
  return "$result"
}

# The reply's length must not depend on the carried number's, so it is read
# back off the calls the run actually made rather than off what this case
# expected: two sizes an order of magnitude apart, one shared length, and
# that length under GitHub's 65,536-character comment limit.
claim_number_reply_length_bounded() {
  local short long short_len long_len result=0
  short=$(digits_of 40000)
  body="/claim ${short}"
  expect_over_length_reply
  run_claim 1 || result=$?
  short_len=$(posted_comment_length)
  long=$(digits_of 60000)
  body="/claim ${long}"
  expect_over_length_reply
  run_claim 1 || result=$?
  long_len=$(posted_comment_length)
  if [[ ! $short_len =~ ^[0-9]+$ || ! $long_len =~ ^[0-9]+$ ]]; then
    printf '  reply length could not be measured: %s and %s\n' \
      "$short_len" "$long_len"
    result=1
  elif [[ $short_len != "$long_len" ]]; then
    printf '  reply length grew with the carried number: %s then %s\n' \
      "$short_len" "$long_len"
    result=1
  elif (( long_len > 65536 )); then
    printf "  reply of %s characters exceeds GitHub's comment limit\n" "$long_len"
    result=1
  fi
  return "$result"
}

claim_number_trailing_prose() {
  body='/claim 526 extra prose'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim 526 extra prose`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim 526 extra prose\n'
}

claim_number_next_line() {
  body=$'/claim\n526'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim\n'
}

claim_uppercase_noncommand() {
  body='/CLAIM 7'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/CLAIM 7`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /CLAIM 7\n'
}

claim_number_attached() {
  body='/claim7'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim7`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim7\n'
}

assignment_post_forbidden() {
  body=/claim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  run_claim 1
}

unclaim_delete_forbidden() {
  body=/unclaim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  run_claim 1
}

comment_forbidden() {
  body=/claim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  run_claim 1
}

unclaim_not_assigned() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

unclaim_one_of_two() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Unassigned @octo-claimant.' --silent
  run_claim 0
}

release_one_of_two() {
  body=/release
  ACTOR=river-helper
  REPOSITORY=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api -X DELETE repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper' --silent
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments --input - 'body=Unassigned @river-helper.' --silent
  run_claim 0
}

closed_issue() {
  body=/claim
  expect_gh '{"state":"closed","assignees":[]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is not open, so `/claim` cannot act on it.' --silent
  run_claim 1
}

malformed_snapshot() {
  body=/claim
  expected_error='parse error: Expecting property name enclosed in double quotes: line 1 column 17 (char 16)'
  expect_gh '{"state":"open",' api repos/owner/project/issues/7
  run_claim 1
}

missing_assignees() {
  body=/claim
  expected_error='issue snapshot must contain an assignees array'
  expect_gh '{"state":"open"}' api repos/owner/project/issues/7
  run_claim 1
}

pull_request() {
  body=/unclaim
  expect_gh '{"state":"open","pull_request":{"url":"https://api.github.com/repos/owner/project/pulls/7"},"assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This is a pull request, so `/unclaim` has no effect here.' --silent
  run_claim 1
}

bot_actor() {
  body=/release
  ACTOR_TYPE=Bot
  run_claim 0 $'not a user: Bot\n'
}

organization_actor() {
  body=/claim
  ACTOR_TYPE=Organization
  run_claim 0 $'not a user: Organization\n'
}

mannequin_actor() {
  body=/claim
  ACTOR_TYPE=Mannequin
  run_claim 0 $'not a user: Mannequin\n'
}

empty_actor_type() {
  body=/claim
  ACTOR_TYPE=
  expected_error='invalid actor-type: expected a nonempty account type'
  run_claim 1
}

multiline_actor_type() {
  body=/claim
  ACTOR_TYPE=$'Bot\nUser'
  run_claim 0 $'not a user: Bot\n'
}

# Issue 26: a caller that configured a user token receives this action's
# replies authored as its own account, and each reply quoting a command word
# re-triggers the workflow — the Bot prefilter only stops accounts GitHub
# itself marks Bot. The action must decline a comment from the account its
# token posts as BEFORE posting anything, so none of its replies can ever be
# the next loop turn. The body is that reply's own text: prose quoting
# `/unclaim`, exactly what a previous turn looks like.
token_commenter_declined() {
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  body='This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.'
  # The self-match scenario writes its own identity fixture, pinning both the
  # override mechanism and that the comparison is against the account the
  # TOKEN posts as, never against some fixed account name.
  printf '%s\n' '{"login":"octo-claimant","id":583271,"type":"User","node_id":"MDQ6VXNlcjU4MzI3MQ==","avatar_url":"https://avatars.githubusercontent.com/u/583271?v=4","html_url":"https://github.com/octo-claimant"}' > "$GH_CASE/identity.response"
  local result=0
  run_claim 0 "commenter is the token's own account: octo-claimant"$'\n' || result=1
  # Nothing may touch the API beyond the identity lookup itself: no issue
  # read, no comment, no assignment — any of those could carry the loop on.
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# Logins are case-insensitive on GitHub, so the guard has to compare the way
# assignment_timeline's spellings map does: the comment author, the event
# actor and the /user answer can spell one account with different letter
# cases and still be the same account.
token_commenter_declined_case_insensitive() {
  body=/claim
  ACTOR=Octo-Claimant
  printf '%s\n' '{"login":"octo-claimant","id":583271,"type":"User","node_id":"MDQ6VXNlcjU4MzI3MQ==","avatar_url":"https://avatars.githubusercontent.com/u/583271?v=4","html_url":"https://github.com/octo-claimant"}' > "$GH_CASE/identity.response"
  local result=0
  run_claim 0 "commenter is the token's own account: octo-claimant"$'\n' || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# The control row: a commenter the token does NOT post as proceeds to the
# issue snapshot exactly as before. The guard refuses its own account only,
# not every comment a user-token caller receives.
distinct_commenter_proceeds() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

# A /user answer the script cannot read must abort like an unreadable issue
# snapshot does: proceeding would compare the commenter against an identity
# that was never established. Two shapes, two cases: not an object, and an
# object with no login string.
malformed_identity_snapshot() {
  body=/claim
  printf '%s\n' '{"type":"User"}' > "$GH_CASE/identity.response"
  expected_error='identity snapshot must contain a login string'
  run_claim 1
}

identity_not_an_object() {
  body=/claim
  printf '%s\n' '[]' > "$GH_CASE/identity.response"
  expected_error='identity snapshot must contain a login string'
  run_claim 1
}

# The stub must fail on what it does not model rather than invent an answer:
# with neither a case fixture nor the suite default present, the identity
# lookup exits 91 like any other unexpected invocation. The run must SURVIVE
# that — the lookup is best effort, and a failed probe is "identity unknown",
# never a verdict about the commenter. Pinning this the other way round was
# the defect: it made the run fatal for every token whose /user refuses.
identity_answer_missing_proceeds() {
  body=/unclaim
  GH_IDENTITY=$GH_CASE/response.absent
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you are not assigned to this issue, so there is nothing to give up.' --silent
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  local result=0
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# The Bot refusal exits before the identity lookup, so a comment the
# workflow's own prefilter already stops costs no API round trip. This pins
# the guard's position below the User check.
bot_commenter_no_identity_call() {
  body=/claim
  ACTOR_TYPE=Bot
  local result=0
  run_claim 0 $'not a user: Bot\n' || result=1
  if [[ -s $GH_CASE/calls.jsonl ]]; then
    printf '  bot refusal must exit before any gh call, got:\n'
    cat "$GH_CASE/calls.jsonl"
    result=1
  fi
  return "$result"
}

# The default `${{ github.token }}` is an App installation token, and /user
# refuses it — verified on an Actions runner 2026-10-01: HTTP 403 "Resource
# not accessible by integration", while a user token answers 200 with the
# account. A 403 identity answer must therefore leave the run exactly as it
# was before the guard existed; this is the control row for the default-token
# majority. The full raw call set is pinned too: one identity call, no retry.
identity_answer_403_proceeds() {
  body=/claim
  printf '%s\n' '{"message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  local result=0
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# Issue 58: a maintainer who hand-assigned every holder inside the claim
# window shares ONE identity across the events, and the settle used to read
# "one shared identity" as "all this action's own writes" — deleting the
# maintainer's hand-made assignment. The shared actor here is
# aaron-maintainer while the suite default identity names
# claim-token-account: attributed to one identity, and provably not ours.
contested_hand_assignment_bails() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"alice"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"aaron-maintainer"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"aaron-maintainer"},"assignee":{"login":"alice"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The same refusal from the default-token side: with no user identity the
# settle needs the single shared actor to be the Bot account an installation
# writes as, and a User-typed maintainer actor is not it. Nothing is removed
# here either — the token proves only its own writes, and these are not.
contested_hand_assignment_bails_integration() {
  body=/claim
  printf '%s\n' '{"message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"alice"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"aaron-maintainer","type":"User"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"aaron-maintainer","type":"User"},"assignee":{"login":"alice"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant this issue is assigned to @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The other side of the same coin: the default-token majority must keep
# settling. Identity unknown (the 403 fixture), but the single shared actor
# is the Bot-typed account an installation token writes as — that IS this
# action's own write, so the later claim is still removed.
contested_integration_still_settles() {
  body=/claim
  printf '%s\n' '{"message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zara-helper"}]}' api repos/owner/project/issues/7
  expect_gh '[[{"id":700,"event":"assigned","actor":{"login":"claim-app[bot]","type":"Bot"},"assignee":{"login":"octo-claimant"}},{"id":800,"event":"assigned","actor":{"login":"claim-app[bot]","type":"Bot"},"assignee":{"login":"zara-helper"}}]]' api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=zara-helper' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
  run_claim 0
}

missing_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

null_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"state":null,"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

nonstring_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"state":42,"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

unknown_state() {
  body=/claim
  expect_gh '{"state":"unknown","assignees":[]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is not open, so `/claim` cannot act on it.' --silent
  run_claim 1
}

malformed_confirm() {
  body=/claim
  expected_error='parse error: Expecting property name enclosed in double quotes: line 1 column 17 (char 16)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open",' api repos/owner/project/issues/7
  run_claim 1
}

# The POST's response is the decline discriminator, so an unreadable one must
# abort the same way an unreadable re-read does: no comment, no verdict.
malformed_post_response() {
  body=/claim
  expected_error='parse error: Expecting property name enclosed in double quotes: line 1 column 17 (char 16)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open",' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  run_claim 1
}

post_response_without_assignees() {
  body=/claim
  expected_error='issue snapshot must contain an assignees array'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open"}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  run_claim 1
}

invalid_issue() {
  body=/claim
  ISSUE='7/comments?x=1'
  expected_error='invalid issue: expected digits'
  run_claim 1
}

invalid_repository() {
  body=/claim
  REPOSITORY='owner/project/issues'
  expected_error='invalid repository: expected owner/name'
  run_claim 1
}

repository_query() {
  body=/claim
  REPOSITORY='owner/project?x=1'
  expected_error='invalid repository: expected owner/name'
  run_claim 1
}

nbsp_noncommand() {
  body=$'\302\240/claim\302\240'
  expect_gh '' api repos/owner/project/issues/7/comments --input - $'body=Not a command: `\302\240/claim\302\240`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: \302\240/claim\302\240\n'
}

em_space_noncommand() {
  body=$'\342\200\203/claim\342\200\203'
  expect_gh '' api repos/owner/project/issues/7/comments --input - $'body=Not a command: `\342\200\203/claim\342\200\203`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: \342\200\203/claim\342\200\203\n'
}

ascii_control_trim() {
  body=$'\v\f/claim\v\f'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

# The C0 separators are NOT whitespace to the shell's [[:space:]], so a body
# delimited by them was never a command. Python's argument-less str.strip()
# does treat them as whitespace, which is exactly the widening this pins shut:
# restoring it makes a body the specification rejects into a valid command.
unit_separator_noncommand() {
  body=$'\037/claim\037'
  expect_gh '' api repos/owner/project/issues/7/comments --input - $'body=Not a command: `\037/claim\037`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: \037/claim\037\n'
}

read_transport_status() {
  body=/claim
  expected_error='gh: transport unavailable'
  expect_gh_failure 42 'gh: transport unavailable' api repos/owner/project/issues/7
  run_claim 42
}

invalid_assignee_snapshot() {
  local assignees=$1 read=$2
  expected_error='issue snapshot assignees must be objects with string logins'
  if [[ $read == initial ]]; then
    body=/unclaim
  else
    body=/claim
    expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
    expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  fi
  expect_gh "{\"state\":\"open\",\"assignees\":$assignees}" api repos/owner/project/issues/7
  run_claim 1
}

null_login_initial() { invalid_assignee_snapshot '[{"login":null}]' initial; }
null_login_confirm() { invalid_assignee_snapshot '[{"login":null}]' confirm; }
null_assignee_initial() { invalid_assignee_snapshot '[null]' initial; }
null_assignee_confirm() { invalid_assignee_snapshot '[null]' confirm; }
missing_login_initial() { invalid_assignee_snapshot '[{}]' initial; }
missing_login_confirm() { invalid_assignee_snapshot '[{}]' confirm; }

action_contract() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import ast
import re
import sys

root = Path(sys.argv[1])
action = (root / "action.yml").read_text()
# Pin this small manifest's explicit layout rather than adding a YAML dependency.
# Full YAML/schema validation belongs to the actionlint workflow.
lines = "\n".join(line for line in action.splitlines()
                  if line.strip() and not line.lstrip().startswith("#"))
inputs, runs = lines.split("\nruns:\n")
inputs = inputs.split("\ninputs:\n")[1]
step = re.fullmatch(
    r"  using: composite\n  steps:\n    - name: [^\n]+\n"
    r"      shell: bash\n      env:\n(?P<env>(?:        [^\n]+\n)+)"
    r"      run: (?P<run>[^\n]+)", runs)
assert step, "expected one claim step with shell: bash and explicit env/run"
assert "${{" not in step["run"], "expressions must not appear in run values"
assert step["run"] == "'python3 \"$GITHUB_ACTION_PATH/claim.py\"'", \
    "claim run must stay quoted and invoke Python with the quoted action path"
env = {}
for line in step["env"].splitlines():
    name, value = line.strip().split(": ", 1)
    assert name not in env, f"duplicate environment name: {name}"
    env[name] = value
script = ast.parse((root / "claim.py").read_text())
script_variables = {
    node.slice.value for node in ast.walk(script)
    if isinstance(node, ast.Subscript)
    and ast.unparse(node.value) == "os.environ"
    and isinstance(node.slice, ast.Constant)
}
# GH_TOKEN is consumed by gh, the script's API client, through its environment.
assert set(env) == script_variables | {"GH_TOKEN"}, "claim step env must match script dependencies"
specs = re.findall(r"^  ([a-z-]+):\n((?:    [^\n]+(?:\n|$))+)", inputs, re.M)
assert len(specs) == 6 and len(dict(specs)) == 6, "expected six distinct inputs"
specs = dict(specs)
expected_inputs = set()
for name, value in env.items():
    binding = re.fullmatch(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", value)
    assert binding, f"{name} must bind an action input"
    expected = "token" if name == "GH_TOKEN" else name.lower().replace("_", "-")
    assert binding[1] == expected, f"{name} must bind inputs.{expected}"
    expected_inputs.add(expected)
    default = re.findall(r"^    default: (.+)$", specs[expected], re.M)
    assert len(default) == 1 and default[0].strip() not in ("", "null", "~"), \
        f"{expected} needs a default"
assert set(specs) == expected_inputs, "inputs must match the environment bindings"
PY
}

# The tripwire for the tripwire. The stub's refusal is what lets a case tell
# an answered command from an unanswered one, and its stdin handling is what
# lets a case see the comment body at all, so both doors need a case of their
# own: delete either and every other case goes quietly blind rather than red.
stub_models_the_body_on_stdin() {
  local at_limit over_limit outer=$GH_CASE status=0 result=0
  at_limit=$(chars_of 65536)
  over_limit=$(chars_of 65537)
  mkdir "$outer/direct"
  GH_CASE="$outer/direct"
  # 65,536 characters is the last legal comment, so the boundary is a body the
  # stub must post and read; only the character past it is one it must refuse.
  : > "$GH_CASE/response.1"
  # The writer's stderr is dropped: a stub that does not read stdin breaks
  # the pipe, and the case below says so in words worth reading.
  printf '%s' "$at_limit" | comment_payload 2> /dev/null \
    | gh api repos/owner/project/issues/7/comments --input - --silent \
      > /dev/null || status=$?
  if (( status != 0 )); then
    printf '  a body of exactly 65536 characters: the stub must post it, got exit %s\n' \
      "$status"
    result=1
  fi
  if ! grep -Fq "\"body=$at_limit\"" "$GH_CASE/calls.jsonl"; then
    printf '  the stub did not read the 65536-character body off stdin\n'
    result=1
  fi
  status=0
  printf '%s' "$over_limit" | comment_payload 2> /dev/null \
    | gh api repos/owner/project/issues/7/comments --input - --silent \
      > /dev/null 2> "$GH_CASE/stderr" || status=$?
  if (( status != 92 )); then
    printf '  a body of 65537 characters: the stub must refuse with 92, got exit %s\n' \
      "$status"
    result=1
  fi
  if ! grep -Fq 'refused a comment body of 65537 characters' "$GH_CASE/stderr"; then
    printf '  the refusal did not name the body it refused:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi
  GH_CASE=$outer
  return "$result"
}

# The entry point's own report of a failure to reach the API. With the body
# off the command line, a gh that is not there is the OSError a run can still
# reach, and without the catch it is a traceback in the run log — the one
# artefact a maintainer reads when the command went unanswered.
unreachable_api_reported_in_its_own_terms() {
  local empty=$GH_CASE/no-gh status=0 result=0
  mkdir "$empty"
  # claim.py runs directly here: the runner puts the stub on PATH for every
  # other case, and this is the case that must not find it.
  env -i PATH="$empty" GH_TOKEN=test-token REPOSITORY=owner/project ISSUE=7 \
    ACTOR=octo-claimant ACTOR_TYPE=User BODY=/claim \
    "$(command -v python3)" "$ROOT/claim.py" \
    > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
  if (( status != 1 )); then
    printf '  exit status: expected 1, got %s\n' "$status"
    result=1
  fi
  if [[ $(wc -l < "$GH_CASE/stderr") != 1 ]] \
      || ! grep -Fq 'could not reach the API: ' "$GH_CASE/stderr"; then
    printf '  stderr: expected one line reporting the failure, got:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi
  if grep -Fq 'Traceback' "$GH_CASE/stderr"; then
    printf '  unexpected traceback\n'
    result=1
  fi
  return "$result"
}

pr_gate_contract() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

def quoted_scalar(text):
    if text.startswith("'"):
        assert re.fullmatch(r"'(?:[^']|'')*'", text), "unsupported single-quoted YAML scalar"
        return text[1:-1].replace("''", "'")
    if text.startswith('"'):
        assert re.fullmatch(r'"[^"\\]*"', text), "unsupported double-quoted YAML escape"
        return text[1:-1]
    return text

path = Path(sys.argv[1]) / ".github/workflows/pr-gate.yml"
assert path.is_file(), "pr-gate workflow must exist"
# Like action_contract, accept this manifest's explicit block layout without
# a YAML dependency. actionlint owns full YAML/schema validation.
nodes = {}
parents = [(-1, ())]
sequences = {}
for raw in path.read_text().splitlines():
    line = re.split(r"\s+#", raw, maxsplit=1)[0].rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    while parents[-1][0] >= indent:
        parents.pop()
    parent = parents[-1][1]
    entry = line.strip()
    if entry.startswith("- "):
        index = sequences.get(parent, 0)
        sequences[parent] = index + 1
        parent += (str(index),)
        nodes[parent] = None
        parents.append((indent, parent))
        indent += 2
        entry = entry[2:]
    pair = re.fullmatch(r"([^:]+):(?:\s+(.*))?", entry)
    assert pair, f"expected explicit workflow mapping: {raw}"
    key, value = quoted_scalar(pair[1].strip()), pair[2]
    if value is not None:
        value = value.strip()
        if value.startswith(("'", '"')):
            value = quoted_scalar(value)
        elif value in ("true", "false"):
            value = value == "true"
        elif value.isdecimal():
            value = int(value)
        if isinstance(value, str) and value.startswith("${{") and value.endswith("}}"):
            value = "${{ " + value[3:-2].strip() + " }}"
    node = parent + (key,)
    assert node not in nodes, f"duplicate workflow key: {'.'.join(node)}"
    nodes[node] = value
    if value is None:
        parents.append((indent, node))

expected = {
    "name": "pr-gate",
    "on/pull_request_target/types": "[opened, edited, reopened]",
    "permissions/contents": "read",
    "permissions/issues": "read",
    "permissions/pull-requests": "write",
    "concurrency/group": "pr-gate-${{ github.event.pull_request.number }}",
    "concurrency/cancel-in-progress": False,
    "jobs/pr-gate/if": "github.event.pull_request.user.type != 'Bot'",
    "jobs/pr-gate/runs-on": "ubuntu-latest",
    "jobs/pr-gate/timeout-minutes": 5,
    "jobs/pr-gate/steps/0/uses":
        "Nitjsefnie-Actions/pr-gate@44437212f1b931f53433b16455bb05aff67ad21e",
    "jobs/pr-gate/steps/0/with/github-token": "${{ github.token }}",
    "jobs/pr-gate/steps/0/with/repository": "${{ github.repository }}",
    "jobs/pr-gate/steps/0/with/pull-request-number": "${{ github.event.pull_request.number }}",
    "jobs/pr-gate/steps/0/with/pull-request-author": "${{ github.event.pull_request.user.login }}",
}
expected = {tuple(key.split("/")): value for key, value in expected.items()}
for node in list(expected):
    for length in range(1, len(node)):
        expected.setdefault(node[:length], None)
assert set(nodes) == set(expected), \
    f"unexpected workflow structure: extra={set(nodes) - set(expected)}, missing={set(expected) - set(nodes)}"
for node, value in expected.items():
    actual = nodes[node]
    if node == ("on", "pull_request_target", "types"):
        assert actual.startswith("[") and actual.endswith("]"), "expected explicit activity list"
        actual = "[" + ", ".join(quoted_scalar(part.strip()) for part in actual[1:-1].split(",")) + "]"
    if node == ("jobs", "pr-gate", "if"):
        if actual.startswith("${{") and actual.endswith("}}"):
            actual = actual[3:-2].strip()
        actual = re.sub(r"\s*!=\s*", " != ", actual)
    assert actual == value, f"wrong workflow value at {'/'.join(node)}: {actual!r} != {value!r}"
PY
}

cases=(sentence multiline interior_cr metacharacters already_assigned trimmed_command
  blank_lines_around_command whitespace_only claimed_by_others claimed_by_three claim_accepted
  contested_winner_by_event_order contested_loser_by_event_order
  contested_equal_event_ids unassigned_login_spelling_clears_map
  assigned_login_spelling_decides
  contested_assign_cycle_decides_current_event
  contested_third_identity_bails contested_unrelated_events_ignored
  cannot_attribute_missing_event bail_with_actor_absent
  unassigned_event_drops_from_current unreadable_event_field_bails
  contested_claim_loser_removed_before_read
  contested_claim_winner_of_three contested_claim_loser_among_three
  contested_removal_forbidden
  claim_accepted_elsewhere claim_with_number claim_with_hash_number unclaim_with_number
  claim_number_mismatch claim_number_over_long claim_number_quoted_in_full
  claim_number_reply_length_bounded claim_number_ceiling_edge
  claim_number_trailing_prose claim_number_next_line
  claim_uppercase_noncommand claim_number_attached claim_rejected
  unclaim_not_assigned unclaim_one_of_two release_one_of_two
  closed_issue malformed_snapshot missing_assignees pull_request bot_actor
  organization_actor mannequin_actor invalid_issue invalid_repository repository_query
  assignment_post_forbidden unclaim_delete_forbidden comment_forbidden action_contract pr_gate_contract
  # The stub itself: what it records, and what it refuses.
  stub_models_the_body_on_stdin stub_counts_characters_not_bytes
  # Who is commenting: the token's own account, and the identity lookup.
  token_commenter_declined
  token_commenter_declined_case_insensitive distinct_commenter_proceeds
  malformed_identity_snapshot identity_not_an_object
  identity_answer_missing_proceeds identity_answer_403_proceeds
  bot_commenter_no_identity_call
  # A hand assignment, which this action did not make and must not settle.
  contested_hand_assignment_bails
  contested_hand_assignment_bails_integration contested_integration_still_settles
  empty_actor_type multiline_actor_type
  missing_state null_state nonstring_state
  unreachable_api_reported_in_its_own_terms
  unknown_state malformed_confirm malformed_post_response
  post_response_without_assignees malformed_events_pages malformed_events_page
  malformed_events_object
  no_assignees_left_after_peer_removals
  nbsp_noncommand em_space_noncommand ascii_control_trim
  unit_separator_noncommand read_transport_status
  null_login_initial null_login_confirm null_assignee_initial null_assignee_confirm
  missing_login_initial missing_login_confirm)
failures=0
for case_name in "${cases[@]}"; do
  GH_CASE="$RUN/$case_name"
  mkdir "$GH_CASE"
  : > "$GH_CASE/expected.jsonl"
  : > "$GH_CASE/calls.jsonl"
  printf '0\n' > "$GH_CASE/sequence"
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
