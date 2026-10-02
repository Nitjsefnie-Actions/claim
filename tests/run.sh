#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(mktemp -d "$ROOT/tests/.run.XXXXXX")"
mkdir "$RUN/bin"
ln -s "$ROOT/tests/gh.sh" "$RUN/bin/gh"
export PATH="$RUN/bin:$PATH"
# GH_IDENTITY is the default answer for the stub's identity lookup
# (`gh api user`); a case overrides it either by writing identity.response into
# its own case directory or by assigning this variable — which is also how a
# case points it at a path with nothing behind it, or supplies the body itself.
# The value is per-case state, set in reset_case below.
export GH_TOKEN REPOSITORY ISSUE ACTOR ACTOR_TYPE GH_CASE GH_IDENTITY MAX_CLAIMS EXPIRE

reset_case() {
  GH_TOKEN=test-token
  REPOSITORY=owner/project
  ISSUE=7
  ACTOR=octo-claimant
  ACTOR_TYPE=User
  MAX_CLAIMS=-1
  EXPIRE=-1
  GH_IDENTITY=$ROOT/tests/identity.response
  body=
  expected_error=
}

expect_gh() {
  local response=$1 ordinal
  shift
  # The expectation goes to the recorder NUL-separated on stdin rather than as
  # arguments, for the same reason the stub does: a case has to be able to
  # state a call the size of the largest comment GitHub accepts, and that
  # string does not fit in one argument.
  printf '%s\0' "$@" | python3 -c '
import json, sys
args = sys.stdin.buffer.read().decode("utf-8").split("\0")[:-1]
sys.stdout.buffer.write((json.dumps(args, separators=(",", ":")) + "\n").encode("utf-8"))
' >> "$GH_CASE/expected.jsonl"
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
  # With an expected line passed, it is written here as it always was. Without
  # one, an expectation the case wrote itself — a quarter-megabyte reply, which
  # is python3's to build — is left alone; and an empty file if there is none.
  if [[ $# -ge 2 ]]; then
    printf '%s' "$expected_output" > "$GH_CASE/expected.stdout"
  elif [[ ! -f $GH_CASE/expected.stdout ]]; then
    : > "$GH_CASE/expected.stdout"
  fi
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

# The character count of the comment body the LAST recorded call posted: the
# reply as it went out, not as the case expected it to. It reads that call's
# own line, so a run whose final call posted no comment measures nothing and
# says so rather than reporting an earlier reply's length — `unmeasured` is a
# word, not a number, so a caller cannot compare or count it by accident.
posted_comment_length() {
  recorded_body_size "$GH_CASE/calls.jsonl"
}

sentence() {
  # A sentence that merely mentions a command word is not an attempt to run
  # one: no line of it starts with the word, so nothing is posted and the run
  # ends quietly, like a bot's comment.
  body='please /claim this when you can'
  run_claim 0 $'no line starts with a command word\n'
}

url_mention_ends_quietly() {
  # The issue's own repro shape: a CI-log analysis whose first line is a
  # Markdown heading and whose later line holds a release-asset URL. No line
  # starts with a command word, so the run ends quietly. The empty
  # expected.jsonl is the assertion: no comment POST happens at all, which is
  # the absence the old behavior could not keep — it answered this with the
  # heading quoted as the offender.
  body=$'## Which code failed\nhttps://github.com/Nitjsefnie-OSC/actionlint/releases/download/v<version>/<asset>'
  run_claim 0 $'no line starts with a command word\n'
}

word_start_on_later_line_declines_that_line() {
  # The pin for the ruling: the decline names the line the command word is
  # on, never the comment's first line, which here holds no command word at
  # all.
  body=$'heading prose\n/claim 7'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 2: `/claim 7`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 2: /claim 7\n'
}

topmost_command_word_wins() {
  # Two lines both start with a command word: the topmost one is declined,
  # because that is the attempt the commenter made first.
  body=$'/unclaim\n/claim'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/unclaim` on line 1: `/unclaim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /unclaim on line 1: /unclaim\n'
}

command_word_needs_a_boundary() {
  # A command word followed by anything other than whitespace or the end of
  # the line — `/claims` from a URL-shaped token, a comma, a path — is part
  # of a longer word, not an attempt at a command, and stays silent. Each
  # shape's expected.jsonl stays empty: no comment POST, exit 0.
  local result=0
  body=/claims
  run_claim 0 $'no line starts with a command word\n' || result=1
  body='/claim,'
  run_claim 0 $'no line starts with a command word\n' || result=1
  body='/claim/7'
  run_claim 0 $'no line starts with a command word\n' || result=1
  return "$result"
}

cr_stripped_before_the_line_scan() {
  # CRs are removed before the trim and the scan, so a Windows client's
  # `/claim\r\nsecond line` is a line that starts with `/claim` followed by
  # the end of the line — declined naming line 1, and the quoted line carries
  # no CR, which the stub's recorded argv would show.
  body=$'/claim\r\nsecond line'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `/claim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim\n'
}

control_chars_escaped_before_both_sinks() {
  # #73: the attempt line reaches two sinks, and both render control
  # characters instead of showing them -- the Actions run log executes ANSI
  # escapes, and the reply carries the line verbatim into a posted comment.
  # ESC (U+001B) and the C1 NEL (U+0085) must leave both sinks as \xNN
  # spellings. U+0085 is spelled as its two UTF-8 bytes the way the NBSP case
  # below spells \302\240: bash emits the characters of $'\u0085' literally
  # under LC_ALL=C. The escapes in the expected strings are literal text.
  body=$'/claim \x1b[31m\xc2\x85x'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `/claim \x1b[31m\x85x`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim \\x1b[31m\\x85x\n'
}

backtick_line_quoted_in_an_unclosable_span() {
  # #74: backslash escapes do not work inside a CommonMark code span, so the
  # old reply closed the span at the line's first backtick and the fixed
  # guidance after it rendered as attacker-shaped fragments. The span must
  # open with a backtick run strictly longer than any run in the line -- here
  # 2 over the line's runs of 1 -- with one space of padding on both sides,
  # so no run in the line can close it and the guidance stays outside.
  # The body's backticks are content, not shell substitutions.
  # shellcheck disable=SC2016
  body='/claim `x`'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `` /claim `x` ``. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim `x`\n'
}

multiline() {
  body=$'/claim\nthis is a second line'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `/claim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim\n'
}

interior_cr() {
  # A CR before the newline is removed before the trim, so this body is
  # "hello there\nsecond line" to the scan and no line of it starts with a
  # command word: prose, not an attempt, and the run ends quietly.
  body=$'hello there\r\nsecond line'
  run_claim 0 $'no line starts with a command word\n'
}

metacharacters() {
  local result=0
  # The literal shell syntax must reach the child unchanged, including both quotes.
  # shellcheck disable=SC2016
  body='$(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'
  body+=$'\nsecond line'
  # No line of this body starts with a command word, so nothing is posted —
  # and the body travels through the environment, never a shell.
  (cd "$GH_CASE" && run_claim 0 $'no line starts with a command word\n') || result=$?
  if [[ -e $GH_CASE/pwned || -e $GH_CASE/backtick-pwned || -e /tmp/pwned ]]; then
    printf '  comment body executed a shell side effect\n'
    result=1
  fi
  return "$result"
}

# The ceiling's reach, driven by a body that is an attempt: a maximum-size
# comment whose FIRST line starts with a command word (`/claim ` plus 65,529
# filler characters, 65,536 in total). The decline reply quotes the line that
# holds the word — here the whole body — which adds the same 187 characters of
# framing as in the emoji case below to the 65,529-character filler: 65,716
# characters, and GitHub refuses that. That is what #50 reports: the commenter
# is answered with the ceiling's sentence instead of nothing at all. The
# mismatch reply one branch above reaches the ceiling the same way.
not_a_command_over_long() {
  body="/claim $(chars_of 65529)"
  # The ceiling's own reply replaces this one, so the only large expectation is
  # the line claim.py prints, and expect_not_a_command writes it.
  expect_not_a_command 65529 chars stdout
  expect_over_length_reply
  run_claim 1
}

# The input class #51 was about, and the only case that pins it. A comment of
# `/claim ` plus 32,740 four-byte characters is 130,967 bytes in the
# environment and legal to GitHub; the decline reply quotes the line that
# holds the word — the whole body here — and is 131,147 bytes, past the
# kernel's 131,072-byte limit on a single argument, and 32,927 characters, so
# the ceiling has nothing to say about it. An argv transport cannot carry that
# reply and dies before the API is reached; only a body off the command line
# gets it posted.
#
# Both margins are deliberate: 105 bytes of headroom under what the
# environment will hold for BODY, 75 over what one argument will hold for the
# reply. The assertion at the end re-measures the posted reply, so a reply
# template that grows or shrinks cannot quietly leave this case testing less
# than it claims.
#
# The window a reply has to sit in is between GitHub's 65,536-character limit
# and the kernel's 131,072-byte limit on one argument, and only a reply that is
# longer in bytes than in characters can occupy it. `Not a command` reaches
# that window because it can quote a body of the commenter's choosing. The
# mismatch reply cannot: it is a command word, digits and fixed wording, all
# ASCII, so its character count and its byte count are the same number and the
# two limits arrive together. say()'s ceiling replaces it at 32,713 carried
# digits, where it is 65,537 characters; it would need 65,481 digits, 131,073
# characters, to reach the argument limit, and it can never be posted that
# long.
#
# It goes red on an argv transport with the expectation sites updated to match,
# which is why it and not claim_number_body_too_long_to_quote is the case that
# proves the transport.
not_a_command_bigger_than_an_argument() {
  local posted result=0
  body="/claim $(emoji_of 32740)"
  # Both expectations here are the size of the payload, so python3 writes them.
  expect_not_a_command 32740 emoji
  run_claim 1 || result=$?
  posted=$(recorded_body_size "$GH_CASE/calls.jsonl" bytes)
  if [[ ! $posted =~ ^[0-9]+$ ]]; then
    printf '  could not measure the posted reply: %s\n' "$posted"
    result=1
  elif (( posted <= 131072 )); then
    printf '  the posted reply is %s bytes, which one argument could have held: this case is no longer driving #51\n' \
      "$posted"
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
  # Whitespace trimmed to nothing is not an attempt at anything: the scan
  # runs over one empty line and finds no command word, so the run ends
  # quietly.
  body=$' \t\r\n '
  run_claim 0 $'no line starts with a command word\n'
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

# The disabled default costs nothing: with MAX_CLAIMS=-1 the exact
# claim_accepted sequence runs, and the expected/recorded diff IS the
# no-role-lookup and no-search assertion — the stub answers the role
# endpoint and search only from the sequence, so any extra call fails the
# case here.
cap_disabled_no_search_call() {
  body=/claim
  MAX_CLAIMS=-1
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# A role the map does not name is unlimited: the role lookup runs so the run
# knows that, and counting does not — no search, straight to the assignment.
cap_unlimited_role_skips_counting() {
  body=/claim
  MAX_CLAIMS='read=2, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"admin","role_name":"admin"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# Under the role's cap: the search runs, counts 5 against 6, and the claim
# proceeds through POST, re-read and the assigned reply exactly as before.
cap_under_limit_proceeds() {
  body=/claim
  MAX_CLAIMS='read=2, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":5,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# At the role's cap: the search's total is compared against that role's cap
# and the claim is refused with the reason on the issue, naming the role.
# The diff pins the absence of a POST — a run that assigned anyway would add
# records the case never expects.
cap_refuses_at_limit() {
  body=/claim
  MAX_CLAIMS='read=2, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":6,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already hold 6 open claims in this repository, and the cap for your role (write) is 6. Comment `/unclaim` (or `/release`) on one you are giving up, then `/claim` again.' --silent
  run_claim 0
}

# A cap of 0 forbids the role outright: refused after the role lookup with no
# search call and no assignment, with the maintainer escape named.
cap_zero_forbids_role() {
  body=/claim
  MAX_CLAIMS='read=0, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant claiming is disabled for your role (read) in this repository. A maintainer can still assign you by hand.' --silent
  run_claim 0
}

# An explicit -1 entry leaves that role unlimited: counted nowhere, assigned
# as usual.
cap_minus_one_entry_is_unlimited() {
  body=/claim
  MAX_CLAIMS='read=2, admin=-1'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"admin","role_name":"admin"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# triage keys its OWN cap, not read's: the fixture is a triage holder whose
# permission field folds to read, and the count of 3 proceeds only because
# the map's triage=4 governs — under read's cap of 2 it would have refused.
cap_triage_role() {
  body=/claim
  MAX_CLAIMS='read=2, triage=4'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"triage"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":3,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# A custom repository role reports its own role_name and the endpoint exposes
# its base only through the folded permission field: release-manager is
# counted under write, and at write's cap the refusal names (write).
cap_custom_role_folds_to_base() {
  body=/claim
  MAX_CLAIMS='read=2, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"release-manager"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":6,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already hold 6 open claims in this repository, and the cap for your role (write) is 6. Comment `/unclaim` (or `/release`) on one you are giving up, then `/claim` again.' --silent
  run_claim 0
}

# Whitespace around an entry is stripped with the entry, never parsed:
# leading/trailing whitespace on the whole value and around a comma both
# land, and the accepted run is byte-for-byte the read=2, write=6 case
# the plain spelling runs.
cap_whitespace_around_entries_accepted() {
  body=/claim
  MAX_CLAIMS=' read=2 , write=6 '
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":5,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# A tab strips like a space — strip() takes all whitespace, not just
# spaces — so the entry grammar sees write=6 clean. Same proceed case.
cap_tab_after_comma_accepted() {
  body=/claim
  MAX_CLAIMS=$'read=2,\twrite=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":5,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# Six malformed values, six cases, one refusal: a negative below -1, a
# role the map cannot name, a duplicate key whose winner would depend on
# entry order, a cap that is not an integer, an entry that strips to
# nothing, and whitespace inside an entry, which stripping cannot reach.
# Each fails the run before any API call beyond the identity lookup —
# the empty expected/recorded diff pins that.
cap_malformed_value_negative_cap() {
  body=/claim
  MAX_CLAIMS='read=-2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

cap_malformed_value_unknown_role() {
  body=/claim
  MAX_CLAIMS='maintainer=3'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

cap_malformed_value_duplicate_key() {
  body=/claim
  MAX_CLAIMS='read=1, read=2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# A cap that is not an integer never reaches the int() conversion: the entry
# grammar refuses it first, and a grammar loosened enough to pass read=two
# would convert it at int() with a different, unhelpful message.
cap_malformed_value_non_integer() {
  body=/claim
  MAX_CLAIMS='read=two'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# An entry that strips to nothing — the trailing comma's empty tail — fails
# the entry grammar like any other shape it cannot parse.
cap_malformed_value_empty_entry() {
  body=/claim
  MAX_CLAIMS='read=2,'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# Whitespace inside an entry is the one place stripping does not reach:
# read =2 keeps its space and fails the grammar like any other value
# the run cannot read.
cap_space_inside_entry_refused() {
  body=/claim
  MAX_CLAIMS='read =2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# A role response without role_name is a snapshot this run cannot read:
# proceeding would compare the cap against a role that was never
# established. No comment, no search.
cap_malformed_role_snapshot() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='role snapshot must contain a role_name string'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

# The other unreadable role shape: the payload is not an object at all, and
# the same refusal fires rather than a role being read out of it.
cap_role_snapshot_not_an_object() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='role snapshot must contain a role_name string'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '[]' api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

# A custom role whose folded base is not one of the five levels leaves the
# cap with no key to read; proceeding would compare the cap against a role
# that was never established.
cap_custom_role_base_unreadable() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='role snapshot must give a readable role'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"role_name":"release-manager","permission":"none"}' api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

# A role lookup transport failure fails the run with gh's own exit status,
# before any comment or search, exactly like the other transport failures.
cap_role_lookup_failure() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='gh: transport unavailable'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 42 'gh: transport unavailable' \
    api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 42
}

# A search response the cap cannot read — a string where the integer belongs —
# aborts the run before any assignment or comment.
cap_malformed_search_response() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='search snapshot must contain a total_count integer'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":"2"}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  run_claim 1
}

# A search transport failure fails the run with gh's own exit status, before
# any assignment or comment.
cap_search_transport_failure() {
  body=/claim
  MAX_CLAIMS='read=2'
  expected_error='gh: transport unavailable'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh_failure 42 'gh: transport unavailable' \
    api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  run_claim 42
}


# The slurped events answer an expiry case expects. The first argument is the
# events' actor as LOGIN or LOGIN|TYPE; each following spec is ID|LOGIN|AGE
# where AGE is DAYS, DAYS:HOURS (hours may be negative) or `none` for an
# event with no readable created_at. Ids stay in the order given.
expected_timeline() {
  python3 - "$@" <<'PYTIMELINE'
import json, sys
from datetime import datetime, timedelta, timezone
login, _, actor_type = sys.argv[1].partition("|")
actor = {"login": login}
if actor_type:
    actor["type"] = actor_type
now = datetime.now(timezone.utc)
events = []
for spec in sys.argv[2:]:
    identifier, assignee, age = spec.split("|")[:3]
    event = {"id": int(identifier), "event": "assigned",
             "actor": actor, "assignee": {"login": assignee}}
    if age != "none":
        days, _, hours = age.partition(":")
        stamp = now - timedelta(days=float(days),
                                hours=float(hours) if hours else 0.0)
        event["created_at"] = stamp.strftime("%Y-%m-%dT%H:%M:%SZ")
    events.append(event)
print(json.dumps([events], separators=(",", ":")))
PYTIMELINE
}


# ---- Claim expiry (issue 61). Ages are relative to real time; the strict
# boundary is pinned from both sides at the closest the clock allows: a
# claim 30 minutes short of the limit is never expired, one an hour past it
# always is.

expire_malformed_zero() {
  body=/claim
  EXPIRE=0
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_below_minus_one() {
  body=/claim
  EXPIRE=-2
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_unit_suffix() {
  body=/claim
  EXPIRE=7d
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_not_a_number() {
  body=/claim
  EXPIRE=abc
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_empty() {
  body=/claim
  EXPIRE=
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

# The disabled default costs nothing even on a claimed issue: no events
# call, no takeover machinery — the empty events expectation IS the
# assertion, because the stub fails loudly on any call the case never
# expected.
expire_disabled_no_timeline_call() {
  body=/claim
  EXPIRE=-1
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

# Expiry is lazy: with expire configured, a claim that lands on an
# UNASSIGNED issue costs nothing beyond the fresh-claim sequence — no
# events read, no role lookup, no search.
expire_fresh_claim_no_expiry_calls() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# Seven days minus an hour: inside the window, today's refusal verbatim.
expire_takeover_inside_window() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|7:-1')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

# The strict boundary's near side: thirty minutes short of seven days is
# still not expired (exactly seven days is not expired either; a real clock
# cannot be made to read exactly 7.0 at both ends of a subprocess run, so
# the near side is pinned as close to the edge as determinism allows).
expire_takeover_boundary_day() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|7:-0.5')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

# An hour past the limit: the holder is deleted, the commenter assigned, the
# re-read confirms, and the reply names holder, age and actor.
expire_takeover_expired() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|7:1')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=The expired claim of @alice (held 7 day(s)) has been taken over by @octo-claimant.' --silent
  run_claim 0 $'took over expired claim of alice (held 7 day(s))\n'
}

# Two expired holders: both are removed in login order and the reply names
# each with its own age.
expire_takeover_multiple_expired() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|9' '810|bob|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=bob' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=The expired claims of @alice (held 9 day(s)) and @bob (held 8 day(s)) have been taken over by @octo-claimant.' --silent
  run_claim 0 $'took over expired claim of alice (held 9 day(s)), bob (held 8 day(s))\n'
}

# The takeover still obeys the cap: a 0 cap for the commenter's role refuses
# with the existing cap-0 reply after the role lookup, and nothing is
# removed.
expire_takeover_cap_zero() {
  body=/claim
  EXPIRE=7
  MAX_CLAIMS='read=0'
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant claiming is disabled for your role (read) in this repository. A maintainer can still assign you by hand.' --silent
  run_claim 0
}

# A reached finite cap refuses with the existing cap reply — searched, not
# deleted.
expire_takeover_cap_reached() {
  body=/claim
  EXPIRE=7
  MAX_CLAIMS='read=1'
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":1,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already hold 1 open claim in this repository, and the cap for your role (read) is 1. Comment `/unclaim` (or `/release`) on one you are giving up, then `/claim` again.' --silent
  run_claim 0
}


# A finite cap with room does not block the takeover: the search counts 1
# against read's cap of 2 and the takeover proceeds through DELETE, POST,
# re-read and the reply.
expire_takeover_cap_under_proceeds() {
  body=/claim
  EXPIRE=7
  MAX_CLAIMS='read=2'
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '{"total_count":1,"items":[]}' api -X GET search/issues -f 'q=repo:owner/project is:issue is:open assignee:octo-claimant'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=The expired claim of @alice (held 8 day(s)) has been taken over by @octo-claimant.' --silent
  run_claim 0 $'took over expired claim of alice (held 8 day(s))\n'
}

# A hand assignment among the holders defeats the takeover however ancient
# the claim looks: proof first, and the proof names an identity that is not
# this action's.
expire_takeover_proof_fails() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline aaron-maintainer '800|alice|400')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

# A current event without created_at leaves the age unestablished: the run
# refuses exactly as today AND says in the run log which holder it could not
# read.
expire_takeover_age_unreadable() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|none')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0 $'no readable age for: alice\n'
}

# One expired holder beside one whose current event carries no created_at:
# only the expired holder is removed, the unreadable one keeps the claim,
# and the run log names the holder it could not read.
expire_takeover_mixed_created_at() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zoe-helper"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|8' '810|zoe-helper|none')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"},{"login":"zoe-helper"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=The expired claim of @alice (held 8 day(s)) has been taken over by @octo-claimant.' --silent
  run_claim 0 $'no readable age for: zoe-helper\ntook over expired claim of alice (held 8 day(s))\n'
}

# GitHub declined the takeover's assignment — the POST response is the
# decline discriminator, so the run refuses and posts nothing about a
# takeover that did not happen.
expire_takeover_post_declined() {
  body=/claim
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '{"state":"open","assignees":[{"login":"someone-else"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=GitHub would not accept @octo-claimant as an assignee here. That usually means the account needs to have commented on or been granted access to this repository.' --silent
  run_claim 1
}

# Privileged release: anyone below write is refused with today's reply and
# no timeline call at all.
expire_release_read_role_refused() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-maintainer/permission
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

expire_release_triage_role_refused() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"triage"}' api repos/owner/project/collaborators/octo-maintainer/permission
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

# write, maintain and admin may release someone else's expired claim.
expire_release_write_role() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

expire_release_maintain_role() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"maintain","role_name":"maintain"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

expire_release_admin_role() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"admin","role_name":"admin"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}


# One expired holder beside one still inside its window: the privileged
# release removes exactly the expired holder, the live claim stays, and the
# reply names only the holder it removed. The removal loop must iterate the
# expired subset, never the whole assignee list.
expire_release_mixed_created_at() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"zoe-helper"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8' '810|zoe-helper|7:-1')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

# write but pre-expiry: today's refusal, nothing removed.
expire_release_write_role_inside_window() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|7:-1')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

# write and the claim is ancient, but a maintainer made the assignment:
# proof fails, nothing is removed.
expire_release_proof_fails() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline aaron-maintainer '800|alice|400')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

# The default-token majority: the token has no user account (the /user 403
# fixture), but the single shared actor is the Bot account an installation
# writes as — the proof holds and the expired claim is released.
expire_release_integration_token() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  printf '%s\n' '{"message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline 'claim-app[bot]|Bot' '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

# Two expired holders, one reply naming each with its age, one DELETE per
# holder in login order.
expire_release_multiple_expired() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|9' '810|bob|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=bob' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 9 day(s)) and @bob's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 9 day(s)), bob (held 8 day(s))\n'
}

# An issue holding nobody cannot have anything expired on it: refused with
# today's reply and no role lookup, no timeline call.
expire_release_no_assignees() {
  body=/release
  ACTOR=octo-maintainer
  EXPIRE=7
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @yuki-dev. @alice was assigned at the same time, so that assignment was removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=You and @zoe-helper claimed this issue at the same time, and @zoe-helper holds it, so your claim was released.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @Zara-Helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant. @Zara-Helper was assigned at the same time, so that assignment was removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @yuki-dev. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @aaron-maintainer, @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @alice, @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. You are not assigned to this issue.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @zara-helper. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=You and @alice claimed this issue at the same time, and @alice holds it, so your claim was released.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant. @sana-helper, @zara-helper were assigned at the same time, so those assignments were removed.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=You and @sana-helper claimed this issue at the same time, and @sana-helper holds it, so your claim was released.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant nothing is assigned to this issue any more.' --silent
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

# The suite's long fixtures, built in python3 rather than in bash. Building one
# of these in bash is a `${var//x/y}` over every character, and bash 3.2 — which
# is what a macOS runner's `env bash` resolves to — takes seconds to do a
# 32,768-character one. This suite makes enough of them to time a job out, on a
# platform nobody here can reproduce. The enumeration belongs in the process
# that does it linearly, and this suite already depends on python3 for
# everything else. Bytes, not text: the suite sets no locale.
filler_of() {
  python3 -c '
import sys
count = int(sys.argv[1])
unit = {"digits": "1", "chars": "x", "emoji": "\U0001F600"}[sys.argv[2]]
sys.stdout.buffer.write((unit * count).encode("utf-8"))
' "$1" "$2"
}

# A carried number of N digits, for a case that needs a body whose number is
# far longer than any issue has.
digits_of() { filler_of "$1" digits; }

# N characters of filler, for a comment body of a length the stub has to judge.
chars_of() { filler_of "$1" chars; }

# N copies of a four-byte character. A body of these is short in characters and
# long in bytes, which is the only way to drive a reply that GitHub accepts and
# an argument list cannot hold — the input class #51 was about.
emoji_of() { filler_of "$1" emoji; }

# What a `Not a command` case expects of a body of a given size, written by
# python3 rather than assembled in the shell: the line claim.py prints and the
# reply it posts are each a quarter of a megabyte, and a case that pins a
# property should not pay for it in bash. The case names a size, a unit, and
# which of the two it wants — a body over the ceiling gets the line but not the
# reply, because the reply it posts is the ceiling's sentence instead. The
# bodies these cases hand over always begin `/claim `, so the word and the
# line it was on are fixed and only the filler varies.
expect_not_a_command() {
  python3 - "$1" "$2" "${3-both}" "$GH_CASE" <<'PYEXPECT'
import json, sys
count, unit, what, case = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
fill = {"digits": "1", "chars": "x", "emoji": "\U0001F600"}[unit] * count
line = f"/claim {fill}"
if what in ("stdout", "both"):
    with open(f"{case}/expected.stdout", "wb") as out:
        out.write(f"not a command: /claim on line 1: {line}\n".encode("utf-8"))
if what in ("reply", "both"):
    call = ["api", "repos/owner/project/issues/7/comments", "--input", "-",
            f"body=Not a command: `/claim` on line 1: `{line}`. Comment one "
            f"of `/claim`, `/unclaim` or `/release` on its own, optionally "
            f"followed by the issue number, for example `/claim 7` or "
            f"`/claim #7`.", "--silent"]
    with open(f"{case}/expected.jsonl", "ab") as out:
        out.write((json.dumps(call, separators=(",", ":")) + "\n").encode("utf-8"))
    # The stub answers call N from response.N, and expect_gh creates that file
    # as it records the call; a call written here needs the same bookkeeping.
    ordinal = sum(1 for _ in open(f"{case}/expected.jsonl", "rb"))
    open(f"{case}/response.{ordinal}", "wb").close()
PYEXPECT
}

# What a mismatch at a given carried number owes as a reply, written by
# python3 for the same reason expect_not_a_command writes its expectations: at
# the ceiling's edge the reply is 65,535 characters, and a case that pins the
# edge should not assemble that in bash. Small numbers are cheaper to write out
# here and are left to expect_gh.
expect_mismatch_reply() {
  python3 - "$1" "$2" "$3" "$GH_CASE" <<'PYMISMATCH'
import json, sys
count, command, issue, case = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
carried = "1" * count
call = ["api", f"repos/owner/project/issues/{issue}/comments", "--input", "-",
        f"body=`{command} #{carried}` names issue {carried}, but this comment "
        f"is on issue {issue}. Comment `{command}` (or `{command} {issue}`) to "
        f"act on this issue.", "--silent"]
with open(f"{case}/expected.jsonl", "ab") as out:
    out.write((json.dumps(call, separators=(",", ":")) + "\n").encode("utf-8"))
ordinal = sum(1 for _ in open(f"{case}/expected.jsonl", "rb"))
open(f"{case}/response.{ordinal}", "wb").close()
PYMISMATCH
}

# The size of the body the LAST recorded call carried, read back off the calls
# the run actually made. Nothing to measure is `unmeasured` rather than an
# error: a run that recorded no call at all — it died before gh was executed —
# has no last line to read, and the caller is owed the same word either way.
# The unit is named because the two limits in play are in different units:
# GitHub counts a comment in characters, the kernel counts an argument in
# bytes, and 65,536 characters can be 262,144 bytes.
recorded_body_size() {
  local file=$1 unit=${2-chars}
  python3 - "$file" "$unit" <<'PYREC'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
if not lines:
    print("unmeasured")
    raise SystemExit
args = json.loads(lines[-1])
body = next((a[len("body="):] for a in args if a.startswith("body=")), None)
if body is None:
    print("unmeasured")
elif sys.argv[2] == "bytes":
    print(len(body.encode("utf-8")))
else:
    print(len(body))
PYREC
}

# Whether a recorded call carried THIS body, rebuilt here rather than handed
# over as a pattern. The bodies a case asks this about are the size GitHub
# accepts: 65,536 characters is a 65,543-byte fixed string, and BSD grep — the
# `grep` a macOS runner resolves — runs out of memory matching one against the
# line it is in, reporting a platform limit as a stub that read no body. So the
# search is python3's, over a body it builds itself, and the comparison is an
# element of a parsed argv: the recorded call has to carry exactly that body,
# which is what grep was being asked for. `yes` or `no`; nothing to search is
# `no`, because a call that recorded nothing carried no body.
recorded_call_carries_body() {
  local file=$1 count=$2 unit=${3-chars}
  python3 - "$file" "$count" "$unit" <<'PYCARRIES'
import json, sys
file, count, unit = sys.argv[1], int(sys.argv[2]), sys.argv[3]
fill = {"digits": "1", "chars": "x", "emoji": "\U0001F600"}[unit] * count
carried = f"body={fill}"
found = any(carried in json.loads(line) for line in open(file))
print("yes" if found else "no")
PYCARRIES
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

# The size that killed a run at the base commit, where the reply was passed as a
# `-f body=…` argument: over about 65,477 digits it crossed the kernel's
# 131,072-byte limit on one argument and the run died with `OSError: [Errno 7]
# Argument list too long` before any API call — nothing posted, nobody
# answered.
#
# It no longer drives an argument list, and it does not prove the transport.
# The ceiling answers this body in 243 characters, so what it proves now is
# that a body far larger than any reply still gets an answer on the issue and a
# failed run. not_a_command_bigger_than_an_argument is the case that pins the
# transport.
claim_number_body_too_long_to_quote() {
  body="/claim #$(digits_of 100000)"
  expect_over_length_reply
  run_claim 1
}

# The mismatch refusal is written from the command word and the issue, so it
# is worded differently for each. Only `/claim` had a case; `/unclaim` and
# `/release` take the same branch, and the ceiling's own sentence names the
# issue it was answering on — which no case checked either.
claim_number_mismatch_other_words() {
  local result=0
  body='/unclaim 8'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    'body=`/unclaim 8` names issue 8, but this comment is on issue 7. Comment `/unclaim` (or `/unclaim 7`) to act on this issue.' \
    --silent
  run_claim 1 || result=$?
  body='/release 8'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - \
    'body=`/release 8` names issue 8, but this comment is on issue 7. Comment `/release` (or `/release 7`) to act on this issue.' \
    --silent
  run_claim 1 || result=$?
  ISSUE=42
  body='/claim 8'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/42/comments --input - \
    'body=`/claim 8` names issue 8, but this comment is on issue 42. Comment `/claim` (or `/claim 42`) to act on this issue.' \
    --silent
  run_claim 1 || result=$?
  # and the same command over the ceiling, on another issue, so the sentence
  # that replaces the answer is known to name the issue it was answering on
  body="/claim #$(digits_of 40000)"
  expect_over_length_reply 42
  run_claim 1 || result=$?
  return "$result"
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
  expect_mismatch_reply 32712 /claim 7
  run_claim 1 || result=$?
  carried=$(digits_of 32713)
  body="/claim #${carried}"
  expect_over_length_reply
  run_claim 1 || result=$?
  carried=$(digits_of 32709)
  body="/release #${carried}"
  expect_mismatch_reply 32709 /release 7
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `/claim 526 extra prose`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim 526 extra prose\n'
}

claim_number_next_line() {
  body=$'/claim\n526'
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Not a command: `/claim` on line 1: `/claim`. Comment one of `/claim`, `/unclaim` or `/release` on its own, optionally followed by the issue number, for example `/claim 7` or `/claim #7`.' --silent
  run_claim 1 $'not a command: /claim on line 1: /claim\n'
}

claim_uppercase_noncommand() {
  # Commands are case-sensitive, and so is the word scan: no line of this
  # body starts with a lowercase command word, so it is prose, not an
  # attempt, and the run ends quietly.
  body='/CLAIM 7'
  run_claim 0 $'no line starts with a command word\n'
}

claim_number_attached() {
  # `/claim7` is one longer token, not a command word followed by a number:
  # the word is not followed by whitespace or the end of the line, so nothing
  # answers it.
  body='/claim7'
  run_claim 0 $'no line starts with a command word\n'
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
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
# lookup exits 91 like any other unexpected invocation. The stub keeps doing
# that, loudly — the question is what the run does with an answer nobody
# modelled, and it must not be "no identity, carry on": an exit 91 carries no
# installation-token refusal, so this is an unknown failure, and the run ends
# before anything is posted or assigned. This case asserted the opposite until
# issue 75, and the difference it now pins is the whole defect: the old row
# could only pass because the probe's reason was thrown away.
identity_answer_missing_fails() {
  body=/unclaim
  GH_IDENTITY=$GH_CASE/response.absent
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: unexpected gh invocation: ["api","user"]'
  local result=0
  run_claim 1 || result=1
  # The empty ordinary-call diff above is the fail-closed assertion; the raw
  # call set pins the rest of it — one lookup, no retry, no write of any kind.
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  local result=0
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# Issue 75: a probe whose reason is not the documented refusal ends the run.
# Five shapes, one refusal, and each is a case that only it decides — a 403
# carrying a different message, a 403 carrying the documented words on the
# BODY but none on stderr, a 403 that opens like the documented one and
# refuses for another reason, a nonzero exit with nothing at all on stderr
# (the branch that reports the status instead of a message gh never wrote),
# and gh's own two-line advice with the status it really exits on (the branch
# that reports all of the message rather than its first line). Each names the
# exit status and the message, and each asserts the empty ordinary-call set: no
# issue read, no comment, no assignment — the whole point is that nothing at
# all happens.
identity_answer_rate_limited_fails() {
  body=/claim
  printf '%s\n' '{"message":"API rate limit exceeded"}' > "$GH_CASE/identity.response"
  printf 'gh: API rate limit exceeded for user ID 42. (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: gh: API rate limit exceeded for user ID 42. (HTTP 403)'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# A 403 is not the documented refusal because of its status code; it is that
# refusal because of what gh says on stderr. This row isolates the two from
# each other: its body is the same JSON the documented refusal carries, so a
# matcher reading the body answers identically to the case above it, and only
# the stderr decides. A bare 403 is news about the run.
identity_answer_other_403_fails() {
  body=/claim
  printf '%s\n' '{"message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  printf 'gh: Forbidden (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: gh: Forbidden (HTTP 403)'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# GitHub words several refusals alike up to the reason, so a phrase match
# short of the documented one would swallow its neighbours: this 403 opens
# with the same three words and refuses for a different reason, and it is the
# phrase's whole length, not its opening, that earns the carve-out.
identity_answer_unrelated_refusal_fails() {
  body=/claim
  printf '%s\n' '{"message":"Resource not accessible by private repository"}' > "$GH_CASE/identity.response"
  printf 'gh: Resource not accessible by private repository (HTTP 403)\n' > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: gh: Resource not accessible by private repository (HTTP 403)'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# gh can fail the probe without writing a word — killed mid-call, or unable
# to reach the API at all. There is no message to quote then, so the refusal
# reports the status it did get; the run still stops before any write.
#
# The answer is stated rather than staged: GH_IDENTITY points at a path with
# nothing behind it and this case writes no body at all, so the status alone is
# the whole answer and the stub reads it from the case directory (#88). A stub
# that still looked for it beside whichever body path won would answer exit 91
# and the run would report the stub's invocation instead of gh's status.
#
# It is also the only row here whose probe wrote nothing on stderr and reached
# the refusal anyway: every other identity row states a message the refusal can
# quote, and identity_answer_missing_fails never gets a modelled answer at all.
# The status is 2 rather than 1 on purpose: what the row holds is that the
# refusal carries the status gh exited with, and a hardcoded 1 in the refusal
# would satisfy every other fixture in this table.
identity_answer_silent_failure_fails() {
  body=/claim
  GH_IDENTITY=$GH_CASE/response.absent
  printf '2\n' > "$GH_CASE/identity.response.status"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: nothing, exit status 2'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# gh's own advice rather than an error message, and the status it really
# exits on — measured on gh 2.98.0 unauthenticated: two lines on stderr, an
# empty stdout, exit 4. This is the shape the `token` input produces when a
# caller passes an empty value, and it is the one a maintainer is handed
# instructions in, so both halves matter: quoting only the first line reads
# like a different failure, and reporting status 1 would be a number gh never
# returned.
#
# Stated rather than staged, like the silent row above: GH_IDENTITY points at
# nothing and no body file is written, so the stderr and the status are stated
# in the case directory (#88). It is the only row in this table whose stderr
# runs to more than one line, and so the only one that holds all of gh's words
# rather than the first of them.
identity_answer_unauthenticated_fails() {
  body=/claim
  GH_IDENTITY=$GH_CASE/response.absent
  printf '%s\n' 'To get started with GitHub CLI, please run:  gh auth login' 'Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.' > "$GH_CASE/identity.response.stderr"
  printf '4\n' > "$GH_CASE/identity.response.status"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: To get started with GitHub CLI, please run:  gh auth login
Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# The other half of what an identity answer is: a body supplied by GH_IDENTITY
# with the status and stderr stated by the case, which is the mixture the two
# rows above cannot reach — they state no body at all. It is also what pins
# where the companions resolve: with GH_IDENTITY winning the body here and
# carrying no companion beside it, a stub that read them beside the path that
# supplied the body (#88) answers exit 0 and hands the run the login below.
# That login is not the commenter's, so the run does not decline there — it
# reads the issue, which this case writes no fixture for, and the case fails
# on a call this shape must never make. No other row separates the two halves
# of an answer. Its status is 7 only in that it is nonzero: the refusal quotes
# the stderr it was given and never the status, so 2 or 9 would pass here
# identically and the number is not a value this row pins.
identity_answer_body_fallback_status_from_case_fails() {
  body=/claim
  printf '%s\n' '{"login":"gh-app-installation","type":"User"}' > "$GH_CASE/answer.body"
  GH_IDENTITY=$GH_CASE/answer.body
  printf '7\n' > "$GH_CASE/identity.response.status"
  printf '%s\n' 'gh: could not resolve the API host' > "$GH_CASE/identity.response.stderr"
  expected_error='cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, and reported: gh: could not resolve the API host'
  local result=0
  run_claim 1 || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

# The refusal is matched in gh's stderr and nowhere else, because the 403
# body is JSON carrying the same text. This row answers 200 with a body that
# carries the phrase AND names the commenter, so a matcher that read stdout
# would return None, skip the self-account guard and go on to read the issue —
# the decline below is what it would lose. Reading the body is what the run
# actually does: it declines the commenter and calls nothing but /user.
identity_body_naming_the_refusal_proceeds() {
  body=/claim
  printf '%s\n' '{"login":"octo-claimant","type":"User","message":"Resource not accessible by integration"}' > "$GH_CASE/identity.response"
  local result=0
  run_claim 0 "commenter is the token's own account: octo-claimant"$'\n' || result=1
  printf '%s\n' '["api","user"]' > "$GH_CASE/expected.calls"
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant this issue is assigned to @alice. This run could not prove every assignment on it was made by this action, so no assignment was changed. Comment `/unclaim` (or `/release`) if you are giving up yours.' --silent
  run_claim 1
}

# The other side of the same coin: the default-token majority must keep
# settling. The token has no user account (the 403 fixture), but the single
# shared actor is the Bot-typed account an installation token writes as — that
# IS this action's own write, so the later claim is still removed.
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
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant. @zara-helper was assigned at the same time, so that assignment was removed.' --silent
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
  # The line starts with the NBSP, not with the word: the trim stops at ASCII
  # whitespace, so the word never starts the line and nothing answers it.
  body=$'\302\240/claim\302\240'
  run_claim 0 $'no line starts with a command word\n'
}

em_space_noncommand() {
  # The EMSP shape, for the same reason as the NBSP above.
  body=$'\342\200\203/claim\342\200\203'
  run_claim 0 $'no line starts with a command word\n'
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
  run_claim 0 $'no line starts with a command word\n'
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

# --- the base-freshness check and the fixtures that drive it ---------------
#
# The check is executable code reached through a CI step, so it is rehearsed by
# EXECUTING it: the run block is taken out of tests.yml the way the platform
# hands it to bash, and run against a real git repository with a real second
# branch and real commits. A double that implemented the assumption the check
# already makes could not tell a working check from a broken one, and a stub
# whose unmodelled branch returns a plausible empty rather than a loud failure
# is harder to see than one that refuses — so everything below refuses.

# The `run:` block of one named step, as the runner would hand it to bash:
# `${{ }}` expanded before a byte of it is executed, and the step's own `env:`
# bound. Written as its own reader rather than reusing the check's, because a
# rehearsal that borrows the code under test finds whatever that code finds —
# including nothing at all, which is a green that measures nothing.
#
# It refuses on anything it does not model rather than guessing: an expression
# it cannot expand, or a `run:` written in a shape it does not read, exits
# non-zero and says which. A rehearsal whose every limb reads false reports the
# harness, not the thing under test.
freshness_step_script() {
  python3 - "$1" "$2" "$3" "$4" <<'PYRUNNER'
import re
import sys

workflow, job, step, target = sys.argv[1:5]
lines = open(workflow, encoding="utf-8").read().splitlines()


def indent(line):
    return len(line) - len(line.lstrip(" "))


def skippable(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def refuse(reason):
    print(f"freshness_step_script: {reason}", file=sys.stderr)
    raise SystemExit(3)


def block_end(start, depth):
    index = start + 1
    while index < len(lines):
        if not skippable(lines[index]) and indent(lines[index]) <= depth:
            break
        index += 1
    return index


def scalar(start, depth, stop):
    body = []
    index = start + 1
    while index < stop:
        if lines[index].strip() and indent(lines[index]) <= depth:
            break
        body.append(lines[index])
        index += 1
    leads = [indent(line) for line in body if line.strip()]
    lead = min(leads) if leads else depth + 2
    return "\n".join(line[lead:] if len(line) > lead else "" for line in body), index


wanted = [index for index, line in enumerate(lines)
          if line.strip() == f"{job}:"]
if len(wanted) != 1:
    refuse(f"expected exactly one `{job}:` job, found {len(wanted)}")
job_span = (wanted[0] + 1, block_end(wanted[0], 2))

entries = [index for index in range(*job_span)
           if not skippable(lines[index]) and indent(lines[index]) == 6
           and lines[index].strip().startswith("- ")]
if not entries:
    refuse(f"job `{job}` has no step entries")

named = [index for index in entries
         if lines[index].strip() == f"- name: {step}"]
if len(named) != 1:
    refuse(f"expected exactly one step named {step!r}, found {len(named)}")
step_span = (named[0] + 1, block_end(named[0], 6))

run, uses, env = None, None, {}
index = step_span[0]
while index < step_span[1]:
    line = lines[index]
    if skippable(line):
        index += 1
        continue
    if indent(line) != 8:
        refuse(f"expected a key in the step, found {line!r}")
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_.-]*):(?:[ \t]+(.*))?", line.strip())
    if not match:
        refuse(f"expected a key in the step, found {line!r}")
    key, value = match[1], (match[2] or "").strip()
    if key == "uses":
        uses = value.split()[0] if value else None
    elif key == "env":
        stop = block_end(index, 8)
        for child in range(index + 1, stop):
            if skippable(lines[child]):
                continue
            pair = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*):[ \t]+(.*)",
                                lines[child].strip())
            if not pair:
                refuse(f"expected an environment binding, found {lines[child]!r}")
            env[pair[1]] = pair[2].strip().strip('"').strip("'")
        index = stop
        continue
    elif key == "run":
        if not value or re.fullmatch(r"[|>][0-9+-]*", value):
            run, index = scalar(index, 8, step_span[1])
            continue
        run = value
    index += 1

if run is None:
    refuse(f"step {step!r} carries no `run:` block")
if uses is not None:
    refuse(f"step {step!r} is a `uses:` step; this rehearsal runs `run:` blocks only")

# The contexts a step's expressions can be expanded from, and nothing else.
# One is unmodelled and refused rather than blanked: an expression expanded to
# an empty string is a different program, and a rehearsal that cannot tell the
# difference is a rehearsal that would go green over a check it never ran.
BINDINGS = {
    "github.repository": "owner/project",
    "github.event.pull_request.number": "7",
    "github.event.pull_request.head.sha": "f" * 40,
    "github.sha": "f" * 40,
    "github.workspace": "WORKSPACE",
    "runner.temp": "RUNNER_TEMP",
    "runner.os": "Linux",
}
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def expand(text, what):
    def substitute(match):
        expression = match[1].strip()
        if expression.startswith("env."):
            name = expression[4:].strip()
            if name not in env:
                refuse(f"{what} reads env.{name}, which the step does not bind")
            return expand(env[name], f"env.{name}")
        if expression in BINDINGS:
            return BINDINGS[expression]
        refuse(f"{what} uses the expression {expression!r}, which this "
               f"rehearsal does not know how to expand")
    return EXPRESSION.sub(substitute, text)


script = ["#!/usr/bin/env bash", "set -eu"]
for name in sorted(env):
    script.append(f"export {name}='{expand(env[name], name)}'")
script.append(expand(run, "the run block"))
open(target, "w", encoding="utf-8").write("\n".join(script) + "\n")
PYRUNNER
}

# A real git repository: a real initial commit, a real second branch, real
# commits on top of a real bare origin, and the repository's own tree copied in
# so the check derives its path set from something real.
#
# The tree is every file this repository tracks, from `git ls-files` rather than
# from a list written here. A hand-written copy list is the same remembered
# shapes the check itself is forbidden to use, and this fixture missed
# `.github/dependabot.yml` that way — a file a required check reads, and a
# change to that check that this case could not see.
#
# The identity is set on the FIXTURE's config, not this repository's and not on
# the command line: these commits are a throwaway repository's history and must
# not touch this repository's identity or its trailer.
gate_fixture() {
  local fixture=$1
  rm -rf -- "$fixture"
  mkdir -p "$fixture/tree"
  python3 - "$ROOT" "$fixture/tree" <<'PYFIXTURE'
import os
import shutil
import subprocess
import sys

root, destination = sys.argv[1], sys.argv[2]
listed = subprocess.run(("git", "-C", root, "ls-files", "-z"),
                        capture_output=True, check=True).stdout
for raw in listed.split(b"\0"):
    if not raw:
        continue
    name = raw.decode("utf-8")
    target = os.path.join(destination, name)
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    shutil.copyfile(os.path.join(root, name), target)
PYFIXTURE
  git init --quiet --initial-branch=main "$fixture/tree"
  git -C "$fixture/tree" config user.email fixture@example.invalid
  git -C "$fixture/tree" config user.name fixture
  gate_commit_all "$fixture/tree" 'base tree'
  git -C "$fixture/tree" branch head-branch
  git init --quiet --bare "$fixture/origin.git"
  git -C "$fixture/tree" remote add origin "$fixture/origin.git"
  git -C "$fixture/tree" push --quiet origin main
}

# Stage and commit a fixture's whole tree. `-f` because the copied `.gitignore`
# denies by default and names back exactly what this repository ships, which
# would hide the very files the states below add — a fixture that quietly
# commits nothing is a fixture whose states measure nothing.
gate_commit_all() {
  git -C "$1" add -A -f
  git -C "$1" commit --quiet -m "$2"
}

# The derived path set for a tree, one path per line. A refusal is the caller's
# to read: a case that cannot derive a set has no verdict to give.
gate_derived_paths() {
  python3 "$ROOT/tests/gate_base_freshness.py" --root "$1" --print-paths
}

# Commit a change to the fixture's main and publish it, leaving the branch the
# caller had checked out alone: the states under test are about what the HEAD
# branch lacks, so the caller puts it back where it wants it.
gate_commit_to_main() {
  local fixture=$1 path=$2 subject=$3 was
  was=$(git -C "$fixture/tree" rev-parse --abbrev-ref HEAD)
  git -C "$fixture/tree" checkout --quiet main
  printf 'a change for %s\n' "$subject" >> "$fixture/tree/$path"
  gate_commit_all "$fixture/tree" "$subject"
  git -C "$fixture/tree" push --quiet origin main
  git -C "$fixture/tree" checkout --quiet "$was"
}

# The plant sits where the commit-scope check reads it: an ancestor of HEAD
# and not of origin/main, carrying exactly this subject. A red verdict is the
# mutant's only when the mutant provably landed in the examined range -- a
# green run sitting beside a plant that never landed is the clean tree
# speaking, and nothing but the readback here can tell the two apart.
gate_commit_in_range() {
  local tree=$1 subject=$2 subjects
  git -C "$tree" merge-base --is-ancestor origin/main HEAD || {
    printf '  the branch has diverged from the fetched base, so the range the check reads is not the one the states describe\n'
    return 1
  }
  if [[ $(git -C "$tree" rev-list --count origin/main..HEAD) -eq 0 ]]; then
    printf '  the outgoing range is empty; the plant never landed\n'
    return 1
  fi
  # The subjects are captured before the match: piped into grep they die of
  # SIGPIPE the moment grep reads its match, and set -o pipefail would read
  # the writer's death as the match's absence -- a plant that provably
  # landed, reported as never having landed, seen here before it was fixed.
  subjects=$(git -C "$tree" log --format=%s origin/main..HEAD)
  if ! grep -Fqx "$subject" <<< "$subjects"; then
    printf '  %s is not a subject in origin/main..HEAD; the plant never landed\n' "$subject"
    return 1
  fi
}

# Run the extracted step against the fixture and put its two streams and its
# status where the caller reads them. `set -e` would stop the case at the first
# non-zero status, and most of the states under test ARE non-zero.
#
# The working tree is named rather than fixed at $fixture/tree, because one
# state runs from a different directory entirely: a depth-1 checkout is what
# actions/checkout hands this job.
gate_run_step() {
  local fixture=$1 script=$2 status=0
  local where=${3-$fixture/tree}
  (cd "$where" && bash "$script" \
    > "$GH_CASE/stdout" 2> "$GH_CASE/stderr") || status=$?
  printf '%s\n' "$status" > "$GH_CASE/status"
}

# The states the check has to tell apart: fresh, main moved on a file no
# required check reads, a planted stale base, and the rebase that clears it.
# Then the three ways it has to refuse rather than answer. Each state runs the
# step's own run block; none of them reaches into the check.
#
# The refusals are the half that matters. A guard that cannot fetch its base,
# cannot find it, or cannot build the path set reports green over a comparison
# it never made, which is the false green this check exists to prevent — and a
# green run is not evidence that it does not.
gate_base_freshness_states() {
  local fixture=$GH_CASE/fixture script=$GH_CASE/step.sh
  local tree=$fixture/tree status result=0 planted
  gate_fixture "$fixture"
  # The step is located by name, so a rename reds this case as well as
  # gate_freshness_step_is_wired rather than quietly rehearsing whatever moved.
  if ! freshness_step_script "$ROOT/.github/workflows/tests.yml" shellcheck \
    "Require this head to carry main's gate-defining commits" "$script"; then
    printf '  the freshness step could not be extracted from tests.yml\n'
    return 1
  fi

  # Fresh: the head IS main, so there is nothing it lacks.
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  fresh head: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stderr"
    result=1
  fi
  # The green line is the one sentence a maintainer reads on this check, so its
  # completeness claim is pinned the way the derivation's is. The suites job
  # reads every tracked file through `.`, which the derivation resolves to
  # nothing, so the count it prints is the files a required check names BY
  # NAME — and the line has to say so. A green line claiming the whole set is
  # the same over-claim the report once made, moved into the emitted string.
  if ! grep -Fqi 'every tracked file' "$GH_CASE/stdout"; then
    printf '  the green line does not carry its own limit. It reports how many\n'
    printf '  files a required check reads, and the suites job reads every\n'
    printf '  tracked file through the . spelling, which the count excludes:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # Main advanced, but only on a file no required check reads. The head is left
  # behind main rather than diverged from it, which is the state a pull request
  # that has not rebased is actually in.
  gate_commit_to_main "$fixture" NOTES.md 'notes only'
  git -C "$tree" checkout --quiet head-branch
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  main moved on NOTES.md, which no required check reads: expected exit 0, got %s\n' \
      "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi

  # Planted stale base: main holds a commit touching tests/run.sh, which the
  # `find tests` in the shellcheck job reads, and the head does not have it. The
  # message has to name that commit and that file — a red that names neither
  # leaves the reader to go and find them.
  gate_commit_to_main "$fixture" tests/run.sh 'touch the suite'
  planted=$(git -C "$tree" rev-parse origin/main)
  gate_run_step "$fixture" "$script"
  status=$(cat "$GH_CASE/status")
  if [[ $status == 0 ]]; then
    printf '  planted stale base: expected a non-zero exit, got 0\n'
    result=1
  fi
  if ! grep -Fq "$planted" "$GH_CASE/stdout"; then
    printf '  the refusal did not name the commit main holds:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  if ! grep -Fq 'tests/run.sh' "$GH_CASE/stdout"; then
    printf '  the refusal did not name the file that commit touched:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # Rebasing onto main is what the message asks for, and it has to clear the
  # red: a check that stays red after the repair is a check nobody can satisfy.
  git -C "$tree" rebase --quiet origin/main
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  head rebased onto main: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi

  # The shape actions/checkout actually hands this job on a pull request: a
  # depth-1 checkout of the MERGE ref, which is not on main's history, while
  # main has moved on since that merge was built. The head's own ancestry is
  # grafted away, so `head..main` cannot tell which of main's commits the head
  # already carries and reports the whole of main against it — naming commits
  # whose content is sitting in the checkout, and every file under them.
  #
  # The assertion is an ABSENCE: the root commit is IN the checkout, so naming
  # it is naming something the head demonstrably carries. That is the difference
  # between a red that costs a rebase and a red that costs the reader an hour.
  git -C "$tree" checkout --quiet -b merge-branch
  printf 'work on the branch\n' >> "$tree/claim.py"
  gate_commit_all "$tree" 'a change on the branch'
  git -C "$tree" checkout --quiet main
  git -C "$tree" merge --quiet --no-ff merge-branch -m 'merge the branch'
  git -C "$tree" push --quiet origin HEAD:pr-merge
  git -C "$tree" reset --quiet --hard HEAD^
  gate_commit_to_main "$fixture" README.md 'move the readme pin'
  planted=$(git -C "$tree" rev-parse origin/main)
  carried=$(git -C "$tree" rev-list --max-parents=0 HEAD)
  git clone --quiet --depth 1 --branch pr-merge "file://$fixture/origin.git" \
    "$fixture/shallow"
  if [[ $(git -C "$fixture/shallow" rev-parse --is-shallow-repository) != true ]]; then
    printf '  the clone under test is not shallow, so this state is not the one it claims\n'
    result=1
  fi
  gate_run_step "$fixture" "$script" "$fixture/shallow"
  status=$(cat "$GH_CASE/status")
  if [[ $status == 0 ]]; then
    printf '  depth-1 checkout with a stale base: expected a non-zero exit, got 0\n'
    result=1
  fi
  if ! grep -Fq "$planted" "$GH_CASE/stdout"; then
    printf '  the depth-1 checkout did not name the commit main holds (%s):\n' "$planted"
    cat "$GH_CASE/stdout"
    result=1
  fi
  if ! grep -Fq 'README.md' "$GH_CASE/stdout"; then
    printf '  the depth-1 checkout did not name the file that commit touched:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  if grep -Fq "$carried" "$GH_CASE/stdout"; then
    printf '  the depth-1 checkout named %s, which its own tree carries:\n' "$carried"
    cat "$GH_CASE/stdout"
    result=1
  fi

  # An unreachable base. Not "an error happened" — the run reports that main
  # could not be fetched, which is the fact a reader needs.
  git -C "$tree" remote set-url origin "$fixture/absent.git"
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  base could not be fetched: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'cannot fetch origin/main' "$GH_CASE/stderr"; then
    printf '  an unreachable base was not reported as one:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi

  # A base that exists but has no main on it: the fetch succeeds and the
  # comparison has nothing to compare against. The other half of "cannot
  # resolve origin/main".
  git init --quiet --bare "$fixture/empty.git"
  git -C "$tree" remote set-url origin "$fixture/empty.git"
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  base ref does not exist: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'origin/main' "$GH_CASE/stderr"; then
    printf '  a base with no main on it was not named:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi

  # A workflow the required jobs cannot be found in: no path set, so no
  # comparison, so a refusal rather than a clean tree.
  git -C "$tree" remote set-url origin "$fixture/origin.git"
  git -C "$tree" fetch --quiet origin main
  python3 - "$tree/.github/workflows/tests.yml" <<'PYRENAME'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
renamed = re.sub(r"^  suites:$", "  suites_renamed:", text, count=1, flags=re.M)
if renamed == text:
    print("the fixture's tests.yml has no `suites:` job to rename", file=sys.stderr)
    raise SystemExit(1)
open(path, "w", encoding="utf-8").write(renamed)
PYRENAME
  gate_commit_all "$tree" 'rename a required job'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  a required job no workflow defines: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'suites' "$GH_CASE/stderr"; then
    printf '  an unbuildable path set did not name the job it could not find:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi
  return "$result"
}

# The derived path set, pinned twice over. First against the repository as it
# stands — exactly the files listed below, which is the control that makes a
# change to the derivation or to a required job loud, in either direction. Then
# against a fixture whose required job starts reading a NEW file, which the set
# must grow to cover, with the same fixture BEFORE that reference as the
# control: the mutant, because a pin that only measured the shipped tree would
# pass on a derivation that had stopped reading the workflows at all.
#
# The shipped half runs on a fixture built from the working tree rather than on
# HEAD. A pin that reads HEAD answers about the last commit and not about the
# tree somebody is editing, which is the same measurement-blindness this suite
# keeps arguing against; and the check reads git's blobs at run time precisely
# because in CI the working tree and HEAD are the same commit anyway.
gate_paths_derived_from_workflows() {
  local result=0 fixture=$GH_CASE/fixture tree derived
  gate_fixture "$fixture"
  tree=$fixture/tree
  derived=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the repository as it stands\n'
    return 1
  }
  local expected='.github/workflows/actionlint.yml
.github/workflows/claim.yml
.github/workflows/codeql.yml
.github/workflows/pr-gate.yml
.github/workflows/requirements.txt
.github/workflows/scorecard.yml
.github/workflows/tests.yml
README.md
action.yml
claim.py
tests/commit_scopes.py
tests/gate_base_freshness.py
tests/gh.sh
tests/identity.response
tests/run.sh'
  if [[ $derived != "$expected" ]]; then
    printf '  the derived path set changed:\n'
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$derived") || true
    result=1
  fi

  # The control: the fixture carries the file, and no required check names it.
  printf 'a gate file nobody reads yet\n' > "$tree/gate-extra.txt"
  gate_commit_all "$tree" 'a file outside the gate'
  derived=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the fixture tree\n'
    result=1
    derived=
  }
  if [[ -n $derived ]] && grep -Fxq 'gate-extra.txt' <<< "$derived"; then
    printf '  gate-extra.txt is in the derived set with no required check naming it\n'
    result=1
  fi

  # The plant: a required job starts reading it.
  python3 - "$tree/.github/workflows/tests.yml" <<'PYPLANT'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = "          find tests -type f -name '*.sh' -exec shellcheck {} +"
if anchor not in text:
    print(f"the fixture's tests.yml has no shellcheck step to extend: {anchor!r}",
          file=sys.stderr)
    raise SystemExit(1)
open(path, "w", encoding="utf-8").write(
    text.replace(anchor, anchor + "\n          cat gate-extra.txt > /dev/null", 1))
PYPLANT
  gate_commit_all "$tree" 'a required job reads a new file'
  derived=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the planted fixture tree\n'
    result=1
    derived=
  }
  if [[ -z $derived ]] || ! grep -Fxq 'gate-extra.txt' <<< "$derived"; then
    printf '  a required job reads gate-extra.txt and the derived set did not grow:\n%s\n' \
      "$derived"
    result=1
  fi
  return "$result"
}

# The step is what makes the check a required status context rather than a
# script nobody runs. Deleting it has to red this suite: the check would still
# be here, still correct, and would never once run.
#
# The primary pin is this one — the step exists, it runs the script, and it sits
# after the checkout and before the lint. The text of the run body is asserted
# because it is the one thing the executable rehearsal cannot catch: the
# rehearsal extracts whatever the body says and runs it, so a body naming a
# different script would be rehearsed happily and pinned green.
# The shapes the same thing can be written in. A reader that answers one
# spelling and stays silent on the next narrows the gate without saying so,
# and the narrowing is indistinguishable from a correct answer until a file
# goes missing from a red nobody expected. Each of these is two-sided: a
# control, and a plant differing from it only in the spelling, because the
# failure is a control that agrees with a narrowing it cannot see.
#
# Nothing here is about the shipped tree's files. It is about whether the
# derivation answers for a second workflow, a one-line step, and a spelling
# this repository does not use today — all three of which arrive with ordinary
# changes, and none of which announces itself.
gate_derivation_handles_every_spelling() {
  local result=0 fixture=$GH_CASE/fixture tree
  local before after planted readable
  gate_fixture "$fixture"
  tree=$fixture/tree

  # The disclosure. `git grep -nI -E '…' -- .` in the suites job reads every
  # tracked file, and `.` resolves to nothing, so that step contributes no
  # paths. CONTRIBUTING.md is the file standing in for the whole of them: it is
  # tracked, it is read by that step, and it is NOT in the derived set.
  #
  # That is a NAMED reach limit rather than a bug, and this assertion is what
  # makes it named rather than silent. Giving resolve() a whole-tree arm is
  # correct and would make this "rebase before you merge" on any change at all,
  # which is `strict_required_status_checks_policy: true` reached through the
  # back door against a ruleset the maintainer set to false on purpose.
  before=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the repository as it stands\n'
    return 1
  }
  if grep -Fxq 'CONTRIBUTING.md' <<< "$before"; then
    printf '  CONTRIBUTING.md is in the derived set, so the whole-tree spelling\n'
    printf '  resolves now; every tracked file is watched and this pin is stale\n'
    result=1
  fi

  # And the OTHER way it can stop being a limit: a required job comes to name
  # CONTRIBUTING.md directly, with the arm absent — which is the state this
  # fixture is in, since the shipped code has no arm. The pin fires either way,
  # and the derivation cannot tell which cause it is looking at, so the message
  # must name BOTH. A message naming one is a red blaming a change nobody made:
  # under this fixture the arm was not added, and saying so would be false.
  # (the second way the limit can end, with the arm still absent)
  python3 - "$tree/.github/workflows/tests.yml" <<'PYNAMED'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = "          find tests -type f -name '*.sh' -exec shellcheck {} +"
if anchor not in text:
    print("the fixture's tests.yml has no shellcheck step to extend", file=sys.stderr)
    raise SystemExit(1)
open(path, "w", encoding="utf-8").write(
    text.replace(anchor, anchor + "\n          cat CONTRIBUTING.md > /dev/null", 1))
PYNAMED
  gate_commit_all "$tree" 'a required job names CONTRIBUTING.md'
  after=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused once a required job named CONTRIBUTING.md\n'
    return 1
  }
  if ! grep -Fxq 'CONTRIBUTING.md' <<< "$after"; then
    printf '  a required job now names CONTRIBUTING.md and it is not in the set\n'
    result=1
  fi
  printf '  CONTRIBUTING.md is now in the derived set, so it is watched. Either\n  the whole-tree arm was added, or a required job now names\n  CONTRIBUTING.md directly; this disclosure pin is stale until the\n  module docstring says which.\n' > "$GH_CASE/message"
  if ! grep -Eiq 'whole.tree' "$GH_CASE/message"; then
    printf '  the disclosure fired without naming the whole-tree arm as one of\n'
    printf '  the two ways it can end\n'
    result=1
  fi
  if ! grep -Eiq 'directly' "$GH_CASE/message"; then
    printf '  the disclosure fired naming ONE cause. Under this fixture the arm is\n'
    printf '  absent, so a message blaming it is a red naming a change nobody made.\n'
    result=1
  fi
  # Back to as it stands for the spellings below, which must not inherit a
  # CONTRIBUTING.md from a reference that was only here to fire the pin. The
  # fixture's own history is stepped back rather than the file patched: a
  # derived set is read at HEAD, so a working-tree edit would not be undone.
  git -C "$tree" reset --quiet --hard HEAD~1

  # A second workflow defining a required job name. A job name is unique within
  # a workflow, not across the repository: `aaa-other.yml` sorts first, so a
  # reader that takes the first match never opens tests.yml's suites job and
  # claim.py — the file that job compiles — leaves the gate with exit 0 and no
  # message. Both halves are asserted: the new file enters, and the old one
  # stays.
  printf 'name: other\non:\n  pull_request:\njobs:\n  suites:\n    runs-on: windows-latest\n    steps:\n      - run: cat CONTRIBUTING.md\n' \
    > "$tree/.github/workflows/aaa-other.yml"
  gate_commit_all "$tree" 'a second workflow defines the same job name'
  after=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused once a second workflow defined the suites job\n'
    return 1
  }
  readable=$(grep -Fxq 'CONTRIBUTING.md' <<< "$after" && printf yes || printf no)
  if [[ $readable != yes ]]; then
    printf '  a second workflow defines the suites job and the files IT reads are\n'
    printf '  absent:\n%s\n' "$after"
    result=1
  fi
  if ! grep -Fxq 'claim.py' <<< "$after"; then
    printf '  a second workflow defines the suites job and claim.py left the set,\n'
    printf '  which is the first-match narrowing this case exists to catch\n'
    result=1
  fi

  # A step written on its own `- ` line. Every checkout step in this repository
  # is spelled this way, and a reader that starts after the dash line reads a
  # step with no keys in it — no path from a `run:` there, and no `uses:` to
  # reach the local-action branch. Two plants, because the two keys fail
  # differently.
  before=$after
  python3 - "$tree/.github/workflows/tests.yml" <<'PYCOMPACT'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
block = """      - name: Compile the claim script
        run: python3 -m py_compile claim.py
"""
compact = "      - run: python3 -m py_compile claim.py\n"
if block not in text:
    print("the fixture's tests.yml has no block-form compile step to compact",
          file=sys.stderr)
    raise SystemExit(1)
open(path, "w", encoding="utf-8").write(text.replace(block, compact, 1))
PYCOMPACT
  gate_commit_all "$tree" 'the compile step on one line'
  after=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the compact-spelling fixture\n'
    return 1
  }
  # Equality, not membership: the finding is that the spelling changed what the
  # gate watches, so a set that merely still contains claim.py would be a second
  # way to be wrong rather than a pass.
  if [[ $before != "$after" ]]; then
    printf '  the same step written on one line derives a different set:\n'
    diff -u <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
    result=1
  fi

  # And the same dash line carrying `uses:`, which is the spelling that used to
  # leave the local-action branch unreachable: a directory nothing else in the
  # repository names, so its absence from the set is only explainable by the
  # step having been read.
  mkdir -p "$tree/local-action"
  printf 'name: local\n' > "$tree/local-action/action.yml"
  python3 - "$tree/.github/workflows/tests.yml" <<'PYLOCAL'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
anchor = "      - name: Require this head to carry main's gate-defining commits"
if anchor not in text:
    print("the fixture's tests.yml has no freshness step to extend", file=sys.stderr)
    raise SystemExit(1)
open(path, "w", encoding="utf-8").write(
    text.replace(anchor, "      - uses: ./local-action\n\n" + anchor, 1))
PYLOCAL
  gate_commit_all "$tree" 'a one-line step uses a local action'
  after=$(gate_derived_paths "$tree") || {
    printf '  the derivation refused on the local-action fixture\n'
    return 1
  }
  planted=local-action/action.yml
  if ! grep -Fxq "$planted" <<< "$after"; then
    printf '  a step says uses: ./local-action and %s is absent, so the\n' "$planted"
    printf '  local-action branch never ran for the one-line spelling\n'
    result=1
  fi

  # Why `resolve()` has no glob arm. A branch that reads a glob metacharacter
  # would look like coverage and reach nothing, because the candidate class
  # cannot produce one — and that is a fact about the reader, not a hole in
  # it, so it is pinned here rather than left to be re-derived. The spelling it
  # would have served is already covered: `.github/workflows/*.yml` breaks at
  # the `*`, and the directory before it takes every workflow whole.
  globbed=$(python3 - "$ROOT" <<'PYGLOB'
import re
import sys
sys.path.insert(0, f"{sys.argv[1]}/tests")
from gate_base_freshness import CANDIDATE
# Whether the class can MATCH a metacharacter, not whether the pattern string
# spells one: the class is written `[A-Za-z0-9._/-]`, which contains brackets.
print(" ".join(c for c in "*?[]" if re.fullmatch(CANDIDATE, c)))
PYGLOB
)
  if [[ -n $globbed ]]; then
    printf '  the candidate class now matches %s, so the absence of a glob arm\n' "$globbed"
    printf '  in resolve() is a hole rather than a fact\n'
    result=1
  fi
  return "$result"
}

# The shapes this reader must REFUSE. Each is real YAML, each carries a step
# list that is right there in the document, and each used to parse into a
# plausible empty — the one outcome a reader built to fail closed must not be
# able to produce. The assertion is that the derivation says so and exits
# non-zero, and the message is checked for the shape it refused, so a refusal
# for some other reason would not pass as this one.
#
# The control is the fixture as it stands: the same derivation, on the same
# tree, answers normally — which is what makes the three refusals refusals
# rather than a reader that cannot read this repository at all.
gate_derivation_refuses_each_unmodelled_shape() {
  local result=0 fixture=$GH_CASE/fixture tree pristine
  gate_fixture "$fixture"
  tree=$fixture/tree
  pristine=$GH_CASE/tests.yml.pristine
  cp "$tree/.github/workflows/tests.yml" "$pristine"
  if ! gate_derived_paths "$tree" > /dev/null 2>&1; then
    printf '  the derivation refused on the repository as it stands, so the\n'
    printf '  refusals below would prove nothing\n'
    return 1
  fi

  # A required job whose steps are a flow sequence. Reading the key's block and
  # finding no entries in it yields an empty step list — a job with steps right
  # there, read as a job with none, and every file they read leaves the gate.
  #
  # Each mutation is COMMITTED before the derivation runs, because the
  # derivation reads the tracked files at HEAD and not the working tree: an
  # uncommitted edit is not a shape the reader has been asked about at all, and
  # a case that measured it would be measuring the wrong thing.
  cp "$pristine" "$tree/.github/workflows/tests.yml"
  python3 - "$tree/.github/workflows/tests.yml" <<'PYFLOW'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
job = text.index("\n  suites:\n")
start = text.index("    steps:\n", job)
stop = text.index("\n", start + 1)
# The step list runs to the next line at the job's own indent, or to the end.
end = len(text)
for offset in range(start + 1, len(text)):
    line = text[offset:].split("\n", 1)[0]
    if line and not line.startswith("    ") and not line.startswith("  "):
        end = offset
        break
    if line.startswith("  ") and not line.startswith("    "):
        end = offset
        break
flow = "    steps: [{run: 'python3 -m py_compile claim.py'}]\n"
open(path, "w", encoding="utf-8").write(text[:start] + flow + text[end + 1:])
PYFLOW
  gate_commit_all "$tree" 'the suites steps as a flow sequence'
  if gate_derived_paths "$tree" > "$GH_CASE/refused" 2>&1; then
    printf '  steps written as a flow sequence: the derivation answered instead of\n'
    printf '  refusing, so a job carrying steps reads as a job carrying none:\n'
    cat "$GH_CASE/refused"
    result=1
  elif ! grep -Fq 'flow' "$GH_CASE/refused" \
    || ! grep -Fq 'block form' "$GH_CASE/refused"; then
    printf '  steps written as a flow sequence: refused, but not by naming it:\n'
    cat "$GH_CASE/refused"
    result=1
  fi

  # A document carrying two top-level `jobs:` mappings. Taking the first is an
  # answer with no message attached, and which half won is not a thing this
  # reader can establish.
  cp "$pristine" "$tree/.github/workflows/tests.yml"
  python3 - "$tree/.github/workflows/tests.yml" <<'PYJOBS'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
second = (
    "jobs:\n"
    "  shellcheck:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - run: cat LICENSE\n"
)
open(path, "w", encoding="utf-8").write(text.rstrip("\n") + "\n\n" + second)
PYJOBS
  gate_commit_all "$tree" 'a second top-level jobs mapping'
  if gate_derived_paths "$tree" > "$GH_CASE/refused" 2>&1; then
    printf '  a second top-level jobs mapping: the derivation answered instead of\n'
    printf '  refusing, so one of the two documents was read and the other was not:\n'
    cat "$GH_CASE/refused"
    result=1
  elif ! grep -Fq 'top-level' "$GH_CASE/refused" \
    || ! grep -Fq 'jobs:' "$GH_CASE/refused"; then
    printf '  a second top-level jobs mapping: refused, but not by naming it:\n'
    cat "$GH_CASE/refused"
    result=1
  fi
  # A job mapping written as a flow mapping. Refused, because which jobs the
  # document defines is then not something a line-at-a-time reader can say —
  # and with the refusal removed the shape parses to `{}`, a required job with
  # steps right there read as a job with none. This is the third refusal of the
  # three, and the only one whose guard was not yet planted: the other two are
  # covered above.
  cp "$pristine" "$tree/.github/workflows/tests.yml"
  python3 - "$tree/.github/workflows/tests.yml" <<'PYFLOWJOBS'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start = text.index("jobs:\n")
flow = ("jobs: {suites: {runs-on: ubuntu-latest, "
        "steps: [{run: 'python3 -m py_compile claim.py'}]}}\n")
open(path, "w", encoding="utf-8").write(text[:start] + flow)
PYFLOWJOBS
  gate_commit_all "$tree" 'the jobs mapping as a flow mapping'
  if gate_derived_paths "$tree" > "$GH_CASE/refused" 2>&1; then
    printf '  jobs written as a flow mapping: the derivation answered instead of\n'
    printf '  refusing, so a document carrying its jobs read as one carrying none:\n'
    cat "$GH_CASE/refused"
    result=1
  elif ! grep -Fq 'flow mapping' "$GH_CASE/refused" \
    || ! grep -Fq 'block form' "$GH_CASE/refused"; then
    printf '  jobs written as a flow mapping: refused, but not by naming it:\n'
    cat "$GH_CASE/refused"
    result=1
  fi

  cp "$pristine" "$tree/.github/workflows/tests.yml"
  return "$result"
}

# `git log --name-only` reports no file for a merge commit, and this repository
# is rebase-merged so main is linear today — a shape that cannot arise on its
# own, which is exactly why it needs pinning: the day a merge lands, a header
# claiming every entry names a file is a sentence the reader cannot check.
#
# The fixture merges two branches that each changed a DIFFERENT file, which is
# what keeps the merge in the report at all: git simplifies a merge away when
# its tree matches either parent, and a merge of one changed branch into an
# unchanged one is exactly that.
#
# The assertion is that no entry is bare. A merge entry says why it names no
# file; every other entry names its file; and the ordinary commits in the same
# report are still named with theirs.
gate_merge_commit_is_reported_honestly() {
  local result=0 fixture=$GH_CASE/fixture script=$GH_CASE/step.sh
  local tree=$fixture/tree status merge side
  gate_fixture "$fixture"
  if ! freshness_step_script "$ROOT/.github/workflows/tests.yml" shellcheck \
    "Require this head to carry main's gate-defining commits" "$script"; then
    printf '  the freshness step could not be extracted from tests.yml\n'
    return 1
  fi
  printf 'a note from main\n' >> "$tree/README.md"
  gate_commit_all "$tree" 'a change on main'
  git -C "$tree" checkout --quiet -b side HEAD~1
  printf 'work on the side branch\n' >> "$tree/claim.py"
  gate_commit_all "$tree" 'a change on the side branch'
  side=$(git -C "$tree" rev-parse HEAD)
  git -C "$tree" checkout --quiet main
  git -C "$tree" merge --quiet --no-ff side -m 'merge the side branch'
  git -C "$tree" push --quiet origin main
  merge=$(git -C "$tree" rev-parse HEAD)
  git -C "$tree" checkout --quiet head-branch
  gate_run_step "$fixture" "$script"
  status=$(cat "$GH_CASE/status")
  if [[ $status == 0 ]]; then
    printf '  a merge on main the head lacks: expected a non-zero exit, got 0\n'
    result=1
  fi
  if ! grep -Fq "$merge" "$GH_CASE/stdout"; then
    printf '  the report did not name the merge commit %s:\n' "$merge"
    cat "$GH_CASE/stdout"
    result=1
  fi
  # The line under the merge entry is the whole finding: a header promising a
  # file per entry, over an entry that names none, is the sentence that is
  # wrong. So the entry has to say why it has no file.
  if ! grep -F -A 1 "$merge" "$GH_CASE/stdout" > "$GH_CASE/merge-context" \
    || ! grep -Fq 'a merge commit' "$GH_CASE/merge-context"; then
    printf '  the merge commit was listed with nothing under it:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  # And the commits it brought in are still named with the files they changed.
  if ! grep -Fq "$side" "$GH_CASE/stdout" \
    || ! grep -Fq 'claim.py' "$GH_CASE/stdout"; then
    printf '  the commits the merge brought in were not named with their files:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  return "$result"
}

gate_freshness_step_is_wired() {
  python3 - "$ROOT" <<'PYWIRE'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1]) / ".github/workflows/tests.yml"
lines = path.read_text().splitlines()
STEP = "Require this head to carry main's gate-defining commits"
SCRIPT = "python3 tests/gate_base_freshness.py"


def fail(message):
    print(f"  {message}")
    raise SystemExit(1)


# The job's KEY is the required context's name, so it is pinned as well as the
# steps: renaming the job would leave this step in a context the ruleset has
# never heard of.
if lines.count("  shellcheck:") != 1:
    fail("tests.yml must keep exactly one `shellcheck:` job")
start = lines.index("  shellcheck:") + 1
end = len(lines)
for index in range(start, len(lines)):
    line = lines[index]
    if line.strip() and not line.lstrip().startswith("#") \
            and len(line) - len(line.lstrip(" ")) <= 2:
        end = index
        break
job = lines[start:end]

steps = []
index = 0
while index < len(job):
    line = job[index]
    if line.strip().startswith("- "):
        steps.append((line.strip()[2:], index))
    index += 1
if not steps:
    fail("the shellcheck job has no steps")


def step_end(at):
    for offset in range(at + 1, len(job)):
        line = job[offset]
        if line.strip().startswith("- "):
            return offset
    return len(job)


named = [at for entry, at in steps if entry == f"name: {STEP}"]
if len(named) != 1:
    fail(f"expected exactly one step named {STEP!r}, found {len(named)}")
at = named[0]
body = job[at + 1:step_end(at)]
runs = [line.strip() for line in body if line.strip().startswith("run:")]
if runs != [f"run: {SCRIPT}"]:
    fail(f"the step must run exactly `{SCRIPT}`, found {runs}")
if any(line.strip().startswith("uses:") for line in body):
    fail("the step must be a run step, not a uses step")

checkout = [at for entry, at in steps if entry.startswith("uses: actions/checkout@")]
if len(checkout) != 1:
    fail(f"expected exactly one checkout step, found {len(checkout)}")
lint = [at for entry, at in steps if entry == "name: Check every shell file"]
if len(lint) != 1:
    fail(f"expected exactly one `Check every shell file` step, found {len(lint)}")
if not checkout[0] < at < lint[0]:
    fail("the freshness step must sit after the checkout and before the lint step")

# The trap actionlint.yml documents for itself: a path filter on a workflow with
# a required job means the check never reports, so every pull request blocks
# forever. It is pinned on EVERY workflow that carries a required job rather than
# on tests.yml alone, because the rule is about the required context and not
# about the file this step happens to live in — and because holding it with the
# comment actionlint.yml carries for itself is holding a rule with prose.
#
# The workflows are DERIVED from the workflows: the same REQUIRED_JOBS the check
# derives its paths from, read out of that module rather than listed here, so
# this pin cannot drift from the set of jobs it is protecting. A `push:` filter
# is not in scope: a push to main is not a merge, so a workflow that does not
# run for one has blocked nothing.
sys.path.insert(0, str(Path(sys.argv[1]) / "tests"))
from gate_base_freshness import REQUIRED_JOBS

workflows = sorted((Path(sys.argv[1]) / ".github/workflows").glob("*.yml"))
carrying = []
for workflow in workflows:
    body = workflow.read_text().splitlines()
    if any(line.rstrip() == f"  {job}:" for line in body for job in REQUIRED_JOBS):
        carrying.append(workflow)
if not carrying:
    fail("no workflow under .github/workflows/ defines a required job, so this "
         "pin protects nothing; REQUIRED_JOBS is empty or every job moved")

for workflow in carrying:
    body = workflow.read_text().splitlines()
    for trigger in ("pull_request:", "pull_request_target:"):
        starts = [index for index, line in enumerate(body)
                  if line.rstrip() == f"  {trigger}"]
        if not starts:
            continue
        stop = len(body)
        for index in range(starts[0] + 1, len(body)):
            line = body[index]
            if line.strip() and not line.lstrip().startswith("#") \
                    and len(line) - len(line.lstrip(" ")) <= 2:
                stop = index
                break
        if any(re.match(r"\s*paths(-ignore)?:", line)
               for line in body[starts[0]:stop]):
            fail(f"{workflow.name}'s {trigger} trigger must carry no paths "
                 f"filter: a workflow with a required job that does not run "
                 f"reports no status, and the pull request blocks forever")

if "  pull_request:" not in lines:
    fail("tests.yml must keep its unfiltered `pull_request:` trigger")
PYWIRE
}

# The commit-scope check's own wiring pin. The rehearsal beside this case
# extracts whatever the run block says and executes it, so the body's text is
# the one thing that case cannot hold: a body naming a different script would
# be rehearsed happily and pinned green. Placement is pinned with the body --
# the check must read the rebased head, which is what sitting after the
# freshness step buys -- and the step must stay unconditional, because an
# `if:` here would skip the check on the very pull requests it exists to
# gate.
commit_scope_step_is_wired() {
  python3 - "$ROOT" <<'PYWIRE'
from pathlib import Path
import sys

path = Path(sys.argv[1]) / ".github/workflows/tests.yml"
lines = path.read_text().splitlines()
STEP = "Refuse a commit whose scope names a workflow outside the ci type"
SCRIPT = "python3 tests/commit_scopes.py"
FRESHNESS = "Require this head to carry main's gate-defining commits"
LINT = "Check every shell file"


def fail(message):
    print(f"  {message}")
    raise SystemExit(1)


# The job's KEY is the required context's name, so it is pinned as well as
# the steps: renaming the job would leave this step in a context the
# ruleset has never heard of.
if lines.count("  shellcheck:") != 1:
    fail("tests.yml must keep exactly one `shellcheck:` job")
start = lines.index("  shellcheck:") + 1
end = len(lines)
for index in range(start, len(lines)):
    line = lines[index]
    if line.strip() and not line.lstrip().startswith("#") \
            and len(line) - len(line.lstrip(" ")) <= 2:
        end = index
        break
job = lines[start:end]

steps = []
index = 0
while index < len(job):
    line = job[index]
    if line.strip().startswith("- "):
        steps.append((line.strip()[2:], index))
    index += 1
if not steps:
    fail("the shellcheck job has no steps")


def step_end(at):
    for offset in range(at + 1, len(job)):
        if job[offset].strip().startswith("- "):
            return offset
    return len(job)


named = [at for entry, at in steps if entry == f"name: {STEP}"]
if len(named) != 1:
    fail(f"expected exactly one step named {STEP!r}, found {len(named)}")
at = named[0]
body = job[at + 1:step_end(at)]
runs = [line.strip() for line in body if line.strip().startswith("run:")]
if runs != [f"run: {SCRIPT}"]:
    fail(f"the step must run exactly `{SCRIPT}`, found {runs}")
if any(line.strip().startswith("uses:") for line in body):
    fail("the step must be a run step, not a uses step")
if any(line.strip().startswith("if:") for line in body):
    fail("the step must stay unconditional: an `if:` here could skip the "
         "check on the very pull requests it exists to gate")

freshness = [at for entry, at in steps if entry == f"name: {FRESHNESS}"]
lint = [at for entry, at in steps if entry == f"name: {LINT}"]
checkout = [at for entry, at in steps if entry.startswith("uses: actions/checkout@")]
if len(freshness) != 1 or len(lint) != 1 or len(checkout) != 1:
    fail("expected exactly one checkout step, one freshness step and one "
         "lint step in the shellcheck job")
if not checkout[0] < freshness[0] < at < lint[0]:
    fail("the commit-scope step must sit after the freshness step and before "
         "the lint step: both compare the head against freshly fetched main, "
         "and both must read the rebased head")
PYWIRE
}

# The states the commit-scope check has to tell apart, rehearsed by executing
# the step's own run block against a real fixture: the planted defect is red
# and names the subject, the scope and the type; the same summary with a scope
# that is not a workflow name, with the ci type on a workflow-name scope, and
# with the exempt claim scope in both directions is green; a plant already
# merged into main is never named; the derivation reads the workflow's NAME
# and never its filename or a job-level name; and the two ways it must refuse
# rather than answer -- a workflow with no name, and a base it cannot resolve
# -- refuse.
#
# Every green here is evidence only because the same fixture went red first:
# the plant in the second state is the liveness proof for the greens that
# follow it, and each state asserts a distinguishing string, so a red that
# names neither the subject nor the scope cannot pass for this check's red,
# and a green that has stopped examining cannot pass for this check's green.
commit_scope_states() {
  local fixture=$GH_CASE/fixture script=$GH_CASE/step.sh
  local tree=$fixture/tree status result=0 planted subject
  if ! freshness_step_script "$ROOT/.github/workflows/tests.yml" shellcheck \
    "Refuse a commit whose scope names a workflow outside the ci type" "$script"; then
    printf '  the commit-scope step could not be extracted from tests.yml\n'
    return 1
  fi
  gate_fixture "$fixture"

  # Fresh: the head IS main, so the outgoing range is empty, and the green
  # line has to say what it examined rather than a bare OK.
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  fresh head: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'Examined 0' "$GH_CASE/stdout"; then
    printf '  the fresh green does not state what it examined:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # The plant: fix(tests) on a change that touches no workflow. The commit is
  # asserted into the range the check examines before its verdict is read,
  # and the red has to name the subject, the scope and the type -- a red that
  # named none of them would leave the reader to find the defect.
  git -C "$tree" checkout --quiet head-branch
  printf 'the plant\n' >> "$tree/NOTES.md"
  gate_commit_all "$tree" 'fix(tests): pin the third refusal, again'
  planted=$(git -C "$tree" rev-parse HEAD)
  subject='fix(tests): pin the third refusal, again'
  gate_commit_in_range "$tree" "$subject" || return 1
  gate_run_step "$fixture" "$script"
  status=$(cat "$GH_CASE/status")
  if [[ $status == 0 ]]; then
    printf '  planted fix(tests): expected a non-zero exit, got 0\n'
    result=1
  fi
  if ! grep -Fq "$planted" "$GH_CASE/stdout" \
    || ! grep -Fq "$subject" "$GH_CASE/stdout"; then
    printf '  the red did not name the planted commit and its subject:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  # Backticks are literal in these patterns; they are message punctuation.
  # shellcheck disable=SC2016
  if ! grep -Fq 'scope `tests`' "$GH_CASE/stdout" \
    || ! grep -Fq 'type `fix` is not `ci`' "$GH_CASE/stdout"; then
    printf '  the red did not name the scope and the type that broke the rule:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # The same summary with a scope that is not a workflow name: type test on
  # scope harness is the shape CONTRIBUTING gives the test machinery, and the
  # workflow-name rule must not reach it. The green is evidence because the
  # identical fixture went red one state ago over the identical summary.
  git -C "$tree" commit --quiet --amend -m 'test(harness): pin the third refusal, again'
  subject='test(harness): pin the third refusal, again'
  gate_commit_in_range "$tree" "$subject" || return 1
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  amended to test(harness): expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'Examined 1' "$GH_CASE/stdout"; then
    printf '  the green after the amend does not say the subject was examined:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # A workflow change in the shape the scope table asks for: the workflow's
  # name with the ci type. The rule flags the type, never the scope, so this
  # must stay green with the name in the set.
  printf 'the tests pin moved\n' >> "$tree/tests/run.sh"
  gate_commit_all "$tree" 'ci(tests): move the tests pin'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  ci(tests): expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'Examined 2' "$GH_CASE/stdout"; then
    printf '  the green after the ci(tests) commit does not say both subjects were examined:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # The claim exemption, in both directions: fix(claim) is exempt because
  # CONTRIBUTING's own sentence makes claim both a workflow name and the
  # script's scope, and ci(claim) is green through the type rule and not
  # through the exemption. A refactor that drops the exemption reds this on
  # the first commit; one that drops the type check reds the ci(tests) state
  # before this one.
  printf 'the script decides\n' >> "$tree/claim.py"
  gate_commit_all "$tree" "fix(claim): the script's own decision"
  printf 'the claim pin moved\n' >> "$tree/README.md"
  gate_commit_all "$tree" 'ci(claim): move the claim pin'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  fix(claim) beside ci(claim): expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'Examined 4' "$GH_CASE/stdout"; then
    printf '  the green over the exempt scope does not say all four subjects were examined:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # Merged-history immunity: the same defect as the plant, already merged
  # into main -- the shape of the two fix(tests) commits from issue #78. The
  # merged subject is asserted onto main and out of the outgoing range, so
  # the green that follows is about the range and not about a subject the
  # check never saw; the red from the second state is what makes this green
  # mean "the range narrowed", not "the oracle is dead".
  gate_commit_to_main "$fixture" CONTRIBUTING.md 'fix(tests): already on main'
  git -C "$tree" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null \
    || {
      printf '  the merged commit never reached the fixture origin; the fixture is not in the state this state describes\n'
      return 1
    }
  # A failed rebase must be loud: a rebase that stopped mid-replay leaves a
  # range the state is not about, and a case that carries on would pin its
  # green over a fixture it did not build.
  if ! git -C "$tree" rebase --quiet origin/main; then
    printf '  the rebase onto the advanced main failed; the fixture is not in the state this state describes\n'
    git -C "$tree" rebase --abort >/dev/null 2>&1 || true
    return 1
  fi
  # Subjects captured, not piped: the SIGPIPE read as an absent match is
  # recorded on the helper above.
  if ! grep -Fqx 'fix(tests): already on main' \
    <<< "$(git -C "$tree" log --format=%s origin/main)"; then
    printf '  the merged subject is not on main (origin/main is at %s), so the immunity green would measure nothing\n' \
      "$(git -C "$tree" rev-parse --short origin/main)"
    return 1
  fi
  if grep -Fqx 'fix(tests): already on main' \
    <<< "$(git -C "$tree" log --format=%s origin/main..HEAD)"; then
    printf '  the merged subject is still in the outgoing range, so this state is not merged immunity\n'
    return 1
  fi
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  rebased onto main holding the merged plant: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if grep -Fq 'already on main' "$GH_CASE/stdout"; then
    printf '  the green named the merged subject:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  if ! grep -Fq 'Examined 4' "$GH_CASE/stdout"; then
    printf '  the green after the rebase does not say the four replayed subjects were examined:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # The NAME drives the set, not the filename: scorecard.yml leaves the
  # fixture and zzz.yml naming itself scorecard takes its place, so the scope
  # scorecard survives in the set only through the name: value -- the file
  # named scorecard is gone. The control is the old filename: fix(zzz) with
  # zzz.yml present is green, because a filename is not a name.
  rm "$tree/.github/workflows/scorecard.yml"
  cat > "$tree/.github/workflows/zzz.yml" <<'YAML'
name: scorecard
on:
  pull_request:
jobs:
  zzz:
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
  gate_commit_all "$tree" 'rename the scorecard workflow'
  printf 'a change under the old filename\n' >> "$tree/NOTES.md"
  gate_commit_all "$tree" 'fix(zzz): rename a job'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  fix(zzz) beside a workflow named scorecard: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'No commit pairs' "$GH_CASE/stdout"; then
    printf '  the filename control did not come back green:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  printf 'a change naming the new workflow\n' >> "$tree/NOTES.md"
  gate_commit_all "$tree" 'fix(scorecard): rename a job'
  gate_run_step "$fixture" "$script"
  status=$(cat "$GH_CASE/status")
  if [[ $status == 0 ]]; then
    printf '  fix(scorecard) with scorecard.yml gone: expected a non-zero exit, got 0\n'
    result=1
  fi
  # shellcheck disable=SC2016
  if ! grep -Fq 'scope `scorecard`' "$GH_CASE/stdout" \
    || ! grep -Fq 'fix(scorecard): rename a job' "$GH_CASE/stdout"; then
    printf '  the red did not name the scope the name: value put in the set:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  # Repair the range for the states that follow: the same summary with a
  # scope that is neither a workflow name nor exempt.
  git -C "$tree" commit --quiet --amend -m 'docs(readme): rename a job'
  subject='docs(readme): rename a job'
  gate_commit_in_range "$tree" "$subject" || return 1

  # A job-level name is not a workflow name: hhh.yml's job displays as
  # `check`, and fix(check) must stay green -- only column 0 is collected.
  # The range now also carries the rename commit, whose subject has no type,
  # so this run doubles as the pin that a subject the check cannot parse is
  # listed and the run stays green: never silent, never a failure.
  cat > "$tree/.github/workflows/hhh.yml" <<'YAML'
name: hhh
on:
  push:
jobs:
  hhh:
    name: check
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
  gate_commit_all "$tree" 'add a workflow whose job carries a name'
  printf 'a change naming the job\n' >> "$tree/NOTES.md"
  gate_commit_all "$tree" 'fix(check): indented'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") != 0 ]]; then
    printf '  fix(check) on an indented name: expected exit 0, got %s\n' "$(cat "$GH_CASE/status")"
    cat "$GH_CASE/stdout" "$GH_CASE/stderr"
    result=1
  fi
  if ! grep -Fq 'No commit pairs' "$GH_CASE/stdout"; then
    printf '  a job-level name reached the rule:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi
  if ! grep -Fq 'not examined' "$GH_CASE/stdout" \
    || ! grep -Fq 'rename the scorecard workflow' "$GH_CASE/stdout"; then
    printf '  the green did not list the subject it skipped:\n'
    cat "$GH_CASE/stdout"
    result=1
  fi

  # An unnamed workflow refuses rather than shrinking the set: yyy.yml starts
  # with on:, and the file whose name cannot be read is the file the refusal
  # names.
  printf 'on:\n  push:\njobs:\n  yyy:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    > "$tree/.github/workflows/yyy.yml"
  gate_commit_all "$tree" 'add a workflow with no name'
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  an unnamed workflow: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'yyy.yml' "$GH_CASE/stderr"; then
    printf '  the refusal did not name the workflow it cannot read:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi

  # A base the check cannot resolve is a refusal, not a green: first an
  # origin that does not exist, then one that exists and has no main on it.
  # Both halves are the same failure to the reader -- the check cannot say
  # what main holds -- and both say so instead of comparing nothing.
  git -C "$tree" remote set-url origin "$fixture/absent.git"
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  an unreachable base: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'cannot fetch origin/main' "$GH_CASE/stderr"; then
    printf '  an unreachable base was not reported as one:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi
  git init --quiet --bare "$fixture/empty.git"
  git -C "$tree" remote set-url origin "$fixture/empty.git"
  gate_run_step "$fixture" "$script"
  if [[ $(cat "$GH_CASE/status") == 0 ]]; then
    printf '  a base with no main on it: expected a non-zero exit, got 0\n'
    result=1
  elif ! grep -Fq 'origin/main' "$GH_CASE/stderr"; then
    printf '  a base with no main on it was not named:\n'
    cat "$GH_CASE/stderr"
    result=1
  fi
  return "$result"
}

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
assert len(specs) == 8 and len(dict(specs)) == 8, "expected eight distinct inputs"
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

# The two reply examples the README quotes in the Claim expiry section are
# restatements of claim.py's takeover_reply/release_reply templates, and
# nothing else holds the pair together: reword either side alone and the
# other drifts while every suite stays green. Both sides are derived live —
# the section's backtick spans on one, the real functions on the other — so
# this case fails on whichever side moved.
readme_quoted_replies() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import importlib.util
import re
import sys

root = Path(sys.argv[1])
readme = (root / "README.md").read_text()
heading = readme.index("### Claim expiry")
section = readme[heading:readme.index("\n## ", heading)]
# The examples wrap across source lines, so normalize each span's
# whitespace, then keep the spans that read as complete reply sentences:
# they name an account and end in a full stop. Exactly two is the sweep
# marker — a third reply the section quotes must not slip past untested.
spans = [" ".join(span.split()) for span in re.findall(r"`([^`]*)`", section)]
replies = [span for span in spans if "@" in span and span.endswith(".")]
assert len(replies) == 2, (
    "expected exactly two quoted reply sentences in the Claim expiry"
    f" section, found {len(replies)}: {replies!r}")

spec = importlib.util.spec_from_file_location("claim", root / "claim.py")
claim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claim)
expired, actor = [("alice", 8)], "bob"

for marker, render in (("taken over by", claim.takeover_reply),
                       ("has released", claim.release_reply)):
    found = [span for span in replies if marker in span]
    assert len(found) == 1, (
        f"expected one {marker!r} span, found {len(found)} among {replies!r}")
    quoted, rendered = found[0], render(expired, actor)
    assert quoted == rendered, (
        f"the reply the README quotes for {marker!r} drifted from claim.py:"
        f"\n  README quotes: {quoted!r}\n  claim.py renders: {rendered!r}")
PY
}

# The Install block's `if:` and claim.yml's `if:` are two hand-kept copies of
# one literal, and the only gate that reads both files — actionlint.yml's
# "Check the README pin matches claim.yml" step — compares the action pins and
# nothing else. Editing either copy alone therefore shipped green. This case
# reads the condition out of BOTH files, each through its own parse of its own
# text, with a reader that models only the shapes these two files use — a
# block-scalar body (whose `#`-initial lines are content there and refuse
# rather than strip), an on-key-line plain or quoted scalar (whose
# deeper-indented continuation lines refuse rather than join), and the wrapper
# forms around those — and refuses every shape outside that set, so a
# condition it cannot read is a red refusal and never a guessed one. The two
# sides are compared with whitespace folded: the folded `>-` scalar's line
# breaks and the more-indented `||` continuation lines compare equal, so only
# a difference in the condition's tokens reddens.
readme_install_condition_matches_claim_yml() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])


def refuse(path, why):
    raise AssertionError(f"{path}: {why}")


def quoted_scalar(path, text):
    if text.startswith("'"):
        assert re.fullmatch(r"'(?:[^']|'')*'", text), \
            f"{path}: unsupported single-quoted YAML scalar: {text!r}"
        return text[1:-1].replace("''", "'")
    if text.startswith('"'):
        assert re.fullmatch(r'"[^"\\]*"', text), \
            f"{path}: unsupported double-quoted YAML escape: {text!r}"
        return text[1:-1]
    return text


def condition_of(path, text):
    """jobs.claim.if read out of one manifest, refusing every shape outside
    the set modelled below."""
    significant = []
    for line in text.splitlines():
        lead = line[: len(line) - len(line.lstrip(" "))]
        if "\t" in lead:
            refuse(path, f"tab-indented line, which YAML forbids: {line!r}")
        stripped = line.strip()
        if not stripped:
            continue
        # A full-line comment rides along flagged, not dropped: inside a
        # block-scalar body a `#`-initial line is CONTENT per YAML, and only
        # the body collector below may decide what one means.
        significant.append((len(lead), stripped, stripped.startswith("#")))

    # Exactly one top-level `jobs:` block. A flow mapping (`jobs: {…}`) or any
    # other inline value is refused, never read.
    inline = [s for indent, s, comment in significant
              if indent == 0 and not comment
              and s.startswith("jobs:") and s != "jobs:"]
    assert not inline, (
        f"{path}: `jobs:` carries an inline value this reader does not model: "
        f"{inline[0]!r}")
    jobs_at = [i for i, (indent, s, comment) in enumerate(significant)
               if indent == 0 and not comment and s == "jobs:"]
    assert len(jobs_at) == 1, (
        f"{path}: expected exactly one top-level `jobs:` block mapping, "
        f"found {len(jobs_at)}")

    start = jobs_at[0] + 1
    stop = next((i for i in range(start, len(significant))
                 if significant[i][0] == 0 and not significant[i][2]),
                len(significant))
    jobs_block = significant[start:stop]

    inline = [s for indent, s, comment in jobs_block
              if indent == 2 and not comment
              and s.startswith("claim:") and s != "claim:"]
    assert not inline, (
        f"{path}: `claim:` carries an inline value this reader does not model: "
        f"{inline[0]!r}")
    claims_at = [i for i, (indent, s, comment) in enumerate(jobs_block)
                 if indent == 2 and not comment and s == "claim:"]
    assert len(claims_at) == 1, (
        f"{path}: expected exactly one `claim:` job at indent 2 under jobs:, "
        f"found {len(claims_at)}")

    start = claims_at[0] + 1
    stop = next((i for i in range(start, len(jobs_block))
                 if jobs_block[i][0] <= 2 and not jobs_block[i][2]),
                len(jobs_block))
    job_block = jobs_block[start:stop]

    # Only a key at indent 4 is the job's own condition: a step's `if:` sits
    # at indent 6 and deeper, inside `steps:`, and must not be picked up.
    ifs_at = [i for i, (indent, s, comment) in enumerate(job_block)
              if indent == 4 and not comment and s.startswith("if:")]
    assert len(ifs_at) == 1, (
        f"{path}: expected exactly one job-level `if:` at indent 4 in the "
        f"claim job, found {len(ifs_at)}")
    rest = job_block[ifs_at[0]][1][len("if:"):].strip()
    assert rest, (
        f"{path}: `if:` carries no value on its key line and no block scalar "
        f"header; an `if:` value on a following line is a shape this reader "
        f"does not model")

    if rest[0] in "|>":
        # The shape both files use: a block scalar. Its header is `|` or `>`
        # with an optional indentation indicator and an optional chomping
        # indicator in either order; anything else is not read. The body is
        # the lines more indented than the key, joined — the caller folds
        # whitespace, so the join owes nothing to YAML's folding rules. A
        # `#`-initial line among them is body content per YAML, never a
        # comment, so it is refused rather than stripped: dropping it would
        # let an edit to the condition hide inside the scalar and read green.
        assert re.fullmatch(r"[|>](?:[1-9][+-]?|[+-][1-9]?)?", rest), \
            f"{path}: unrecognized block scalar header: {rest!r}"
        body = []
        for indent, s, comment in job_block[ifs_at[0] + 1:]:
            if comment:
                if indent > 4:
                    refuse(path, f"a `#`-initial line inside a block scalar "
                                 f"body, which is content there and not a "
                                 f"comment: {s!r}")
                break
            if indent <= 4:
                break
            body.append(s)
        return " ".join(body)

    if rest[:1] in ("'", '"'):
        value = quoted_scalar(path, rest)
    else:
        assert " #" not in rest, (
            f"{path}: trailing comment in a plain scalar, which this reader "
            f"does not model: {rest!r}")
        assert rest[0] not in "&*!?%@`{[", (
            f"{path}: a value opening with the indicator {rest[0]!r} is a "
            f"shape this reader does not model: {rest!r}")
        value = rest
    if value.startswith("${{") and value.endswith("}}"):
        value = value[3:-2].strip()
    assert "${{" not in value and "}}" not in value, (
        f"{path}: embedded expression this reader does not model: {rest!r}")
    # An on-key-line scalar ends at its own line: per YAML a deeper-indented
    # line after one CONTINUES the scalar, so an extra conjunct indented past
    # the key would silently join a condition this reader never reads. It is
    # refused, never skipped. A `#` line is a real comment outside a block
    # scalar, and stays skipped, as everywhere above.
    followers = [(indent, s) for indent, s, comment
                 in job_block[ifs_at[0] + 1:] if not comment]
    if followers and followers[0][0] > 4:
        refuse(path, f"a continuation line after an on-key-line `if:` value "
                     f"is a shape this reader does not model: "
                     f"{followers[0][1]!r}")
    return value


readme = (root / "README.md").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/claim.yml").read_text(encoding="utf-8")

# The Install block's fence is the one yaml fence whose content carries a
# top-level `jobs:` key line: the README's other yaml fence quotes a `with:`
# block, and must not match. Zero or two candidates is a README this case
# cannot read, not a comparison it guesses at.
fences = re.findall(r"^```yaml\n(.*?)\n```", readme, re.M | re.S)
installs = [fence for fence in fences if re.search(r"^jobs:\s*$", fence, re.M)]
assert len(installs) == 1, (
    f"expected exactly one ```yaml fence in README.md whose content carries a "
    f"top-level `jobs:` key line, found {len(installs)} among {len(fences)} "
    f"yaml fence(s)")


def fold(text):
    return " ".join(text.split())


readme_condition = fold(condition_of("README.md install block", installs[0]))
workflow_condition = fold(condition_of(".github/workflows/claim.yml", workflow))
assert readme_condition == workflow_condition, (
    "the README install block's job condition drifted from claim.yml's:"
    f"\n  README.md: {readme_condition!r}"
    f"\n  claim.yml: {workflow_condition!r}")
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
  # The stub numbers its answers from this counter, not from the number of
  # recorded calls, so a call it REFUSES — which records and then exits before
  # the counter moves — does not shift the numbering. Seed it here the way the
  # runner seeds it for a case, and the third call below is response.2.
  printf '0\n' > "$GH_CASE/sequence"
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
  if [[ $(recorded_call_carries_body "$GH_CASE/calls.jsonl" 65536) != yes ]]; then
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
  # And the largest comment GitHub accepts, in four-byte characters: 65,536 of
  # them is 262,144 bytes, twice what one argument can hold. Recording a body
  # that size as an argument is how the stub used to kill itself with the
  # shell's 126 on a body it was supposed to be modelling.
  : > "$GH_CASE/response.2"
  status=0
  printf '%s' "$(emoji_of 65536)" | comment_payload 2> /dev/null \
    | gh api repos/owner/project/issues/7/comments --input - --silent \
      > /dev/null || status=$?
  recorded=$(recorded_body_size "$GH_CASE/calls.jsonl")
  # `unmeasured` is a word, and this is the one place that hands it to bash
  # arithmetic, which reads a bare name as a variable and not as a number:
  # under `set -u` a run that recorded nothing at all died here with
  # `unmeasured: unbound variable` instead of reaching the diagnostic below.
  # A measurement that did not happen is not a length that differs, and the
  # other two callers of recorded_body_size already say so before comparing.
  if [[ ! $recorded =~ ^[0-9]+$ ]]; then
    printf '  could not measure what the stub recorded: %s\n' "$recorded"
    result=1
  elif (( status != 0 || recorded != 65536 )); then
    printf '  65536 four-byte characters: exit %s, recorded %s characters, expected 0 and 65536\n' \
      "$status" "$recorded"
    result=1
  fi
  GH_CASE=$outer
  return "$result"
}

# The run's own report, located on the descriptor rather than counted on it.
# It has to be there once, as a whole line of its own: a line of its own is
# what separates a run that reported from a traceback frame that happens to
# contain the same words, which a substring search cannot tell apart.
#
# Anything else on the descriptor is printed WITHOUT failing the case. That is
# deliberate, and it is the only place in the suite that speaks on a passing
# case: a macOS runner puts a line here that this run did not write, it is not
# yet known what writes it, and a check that quietly tolerates an unexplained
# line is worth less than one that keeps showing it to whoever has to read the
# log. When the line is identified it is either the run's own — and asserted —
# or the platform's, and this can become a check that skips it by content.
reports_failure_once() {
  python3 - "$1" <<'PYREPORT'
import sys
prefix = "could not reach the API: "
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
reports = [line for line in lines if line.startswith(prefix)]
if len(reports) != 1:
    print(f"  stderr: expected the run to report the failure once, "
          f"got {len(reports)} reports")
for line in lines:
    if not line.startswith(prefix):
        print(f"  also on stderr: {line!r}")
sys.exit(0 if len(reports) == 1 else 1)
PYREPORT
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
  # What is under test is that the failure is reported in the run's own terms
  # rather than as a Python error, and the checks for that are the two below:
  # the run's line is on the descriptor, on a line of its own, and no traceback
  # is on it at all.
  #
  # It used to be a line COUNT, which was a proxy for the same property and
  # which a platform broke: `env -i` empties the environment, and on a macOS
  # runner something outside this run's control — the interpreter's own
  # start-up, most likely — puts a second line on the same descriptor. The
  # count cannot tell that apart from a second line out of the run, so it read
  # the platform's noise as a leak. reports_failure_once asks the question
  # directly and prints the noise instead of failing on it.
  if ! reports_failure_once "$GH_CASE/stderr"; then
    result=1
  fi
  if grep -Fq 'Traceback' "$GH_CASE/stderr"; then
    printf '  unexpected traceback\n'
    result=1
  fi
  return "$result"
}

# Which unit the stub counts in. GitHub's limit is 65,536 characters and
# claim.py's ceiling counts characters, so a comment of exactly 65,536 emoji
# is legal and has to be posted. Bash's ${#body} counts characters or bytes
# according to the ambient locale, and the suite sets none: under LC_ALL=C it
# would call that body 262,144 and refuse it, which reads as a product defect
# rather than as a harness disagreement about units.
stub_counts_characters_not_bytes() {
  local outer=$GH_CASE filler status=0 result=0 recorded
  filler=$(emoji_of 65536)
  mkdir "$outer/locale"
  GH_CASE="$outer/locale"
  printf '0\n' > "$GH_CASE/sequence"
  : > "$GH_CASE/response.1"
  printf '%s' "$filler" | comment_payload 2> /dev/null \
    | LC_ALL=C gh api repos/owner/project/issues/7/comments --input - --silent \
      > /dev/null 2> "$GH_CASE/stderr" || status=$?
  recorded=$(recorded_body_size "$outer/locale/calls.jsonl")
  GH_CASE=$outer
  if (( status != 0 )); then
    printf '  65536 emoji under LC_ALL=C: the stub must post them, got exit %s\n' \
      "$status"
    cat "$outer/locale/stderr"
    result=1
  fi
  if [[ $recorded != 65536 ]]; then
    printf '  the recorded body is %s characters, expected 65536\n' "$recorded"
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

# The CodeQL matrix, read by structure: the languages it names, whether every
# entry is complete, and whether anything reads the value they are named by.
#
# The third limb is what a pin on the file's text cannot give. A matrix entry
# nothing consumes analyses nothing — GitHub still runs the job, `init`
# extracts its default language set, and the SARIF lands with no category the
# run can be found by. So this reads the three consumers of the value: the job
# name, the init step's `languages:` and the analyze step's `category:`, and
# requires all three to interpolate `matrix.language`.
#
# `python` is the one membership requirement held by hand, and it is held by
# hand for a checkable reason: the offline oracle for "which languages does
# CodeQL offer this repository" is the live `code-scanning/default-setup` API —
# `gh api repos/Nitjsefnie-Actions/claim/code-scanning/default-setup --jq
# .languages` answers ["actions","python"] — and a test cannot call it, so the
# matrix is where that answer is recorded. It is deliberately a membership test
# and not an equality, so a third language a maintainer adds legitimately does
# not have to rewrite this pin to go green.
#
# The reader's ADMITTED SUBSET, and the refusal set is everything else it
# meets. The admitted subset is: an explicit block mapping; scalars that are
# plain and stay plain under PyYAML's own implicit resolver, or quoted without
# escapes, or `{}`; sequences that are block sequences of mappings and scalars;
# a node carrying an `&anchor` and/or the string tag `!!str` or its long form
# `!<tag:yaml.org,2002:str>`, which are stepped over in EITHER position, and a
# property with no content, which is stepped over so the block after it is read;
# and every path this case reads carried as a block.
#
# "Stays plain under PyYAML's own implicit resolver" is the whole of what a
# usable value is, and it is transcribed from PyYAML's resolver table rather
# than spelled out here. The five types it resolves -- bool, float, int, null,
# timestamp -- plus the two it cannot construct safely (`<<` and `=`, which it
# rejects outright) are every implicit resolution YAML makes, and each becomes a
# non-string, so the usable-value check asks what the value BECAME. A reader
# that enumerated those spellings by hand is what resolved `true` and `false`
# and missed `no`.
#
# Each refusal below is one a plant reaches and a refusal message names:
#   - a block scalar, on its first character, in value position OR as a whole
#     sequence entry (`- |`). Properties are stripped BEFORE the test, which is
#     what lets it key on the first character at all: `!!str |` has become `|`
#     by then. Keying on the LAST token instead — the obvious fix for the same
#     hole — would refuse `run: echo x >`, which PyYAML accepts as a plain
#     scalar, so that repair was measured and rejected;
#   - a TYPE-CHANGING tag (`!custom`, `!!binary`, `!!int`, `!!bool`), because a
#     tag decides what the value became and this reader does not model that.
#     The exemption is a predicate on the tag URI, not a list of spellings, so
#     `!!str` and `!<tag:yaml.org,2002:str>` are both recognised as ONE tag and
#     `!str` is correctly not it (PyYAML rejects that document);
#   - a tag on a node that turns out to be a block -- `include: !!str` over a
#     sequence is a PyYAML ConstructorError. An anchor carries no such claim,
#     so `include: &m` over a sequence is read as the sequence;
#   - an alias, in value position or as a sequence entry (`*m`), because its
#     referent is declared elsewhere and no alias is resolved;
#   - `?` in value position, an indicator no plain scalar may start with, which
#     PyYAML rejects;
#   - a second anchor on one node (`&a &b python`), which PyYAML rejects;
#   - a flow collection other than `{}`, which hides structure this reader
#     cannot walk;
#   - a merge key `<<`, whose contributed keys are unanswerable;
#   - a duplicate key at one path;
#   - two mappings on one line (`: ` inside a plain scalar), which PyYAML
#     rejects too;
#   - a tab-indented line, which YAML forbids and this reader would count as
#     no indentation and silently re-parent;
#   - an ambiguous `- ` sequence entry, and a quoted scalar carrying an
#     escape the reader does not model;
#   - a path that must be a block but is absent, inline, or a bare key;
#   - a job without exactly one `init` step and exactly one `analyze` step.
#
# STEPS OVER rather than refuses, because PyYAML reads these as the plain
# content they are and refusing them would be a false refusal of valid YAML:
#   - an anchor, in value position (`&l python` IS `python`) and as a bare
#     sequence entry (`- &m` over two keys IS that mapping);
#   - the explicit string tags `!!str` and `!<tag:yaml.org,2002:str>`, which
#     assert a value is the string a plain scalar already is, and the bare `!`,
#     which asserts nothing at all. `!!int '3'` is not one of these and is
#     refused. Note that only the EXPLICIT string tags bypass the implicit
#     resolver: PyYAML reads `fail-fast: ! false` as False, because a
#     non-specific tag leaves the resolver to decide, so `!` must not be
#     treated as forcing a string.
#
# Four limits it does NOT refuse, stated rather than assumed away. Each is a
# shape this reader READS, not one it rejects, so none is a refusal to plant:
#   - `${{ }}` is normalised for spacing everywhere it occurs and resolved
#     nowhere, so a reference written `matrix . language` reads unequal to
#     `matrix.language`. That direction reddens rather than greens, and
#     pr_gate_contract does the same.
#   - A plain scalar holding `:` with NO space after it is read as part of the
#     value: PyYAML reads `language: python:3` as the language `python:3`, and
#     so does this reader. The membership limb then reports it; the same shape
#     in a `build-mode:` would not be reported.
#   - An anchor is stepped over, never RESOLVED. This reader resolves no
#     reference between anchors, so an anchor that shadows a key another node
#     reads is invisible to it.
#   - It reads no trigger. `on:` is outside this case's declared scope:
#     deleting the push trigger answers green here, and the WHOLE SUITE
#     answers green on it too — measured, not assumed.
codeql_matrix_covers_python() {
  python3 - "$ROOT" <<'PYCODEQL'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1]) / ".github/workflows/codeql.yml"


def refuse(reason):
    print(f"codeql_matrix_covers_python: {reason}", file=sys.stderr)
    raise SystemExit(3)


STRING_TAG = "tag:yaml.org,2002:str"


def tag_is_string(spelling):
    """Whether a tag property names the string type.

    Decided by resolving the spelling to a tag URI, not by comparing it against
    a list of accepted spellings: the default tag directives make `!!str` and
    `!<tag:yaml.org,2002:str>` two spellings of ONE tag, and a rule that can
    only recognise the spellings it was told about is a lookup wearing a
    predicate's clothes. `!str` is NOT the string tag -- PyYAML resolves it
    against the `!` handle to a namespace the default directives do not define
    and rejects the document.
    """
    if spelling.startswith("!<") and spelling.endswith(">"):
        return spelling[2:-1] == STRING_TAG
    if spelling.startswith("!!"):
        return "tag:yaml.org,2002:" + spelling[2:] == STRING_TAG
    return spelling == "!"


# What a plain scalar BECOMES, transcribed from PyYAML's own implicit
# resolver table rather than enumerated by hand. Each entry is (pattern, first
# characters, kind) exactly as PyYAML registers it, and they are tried in
# PyYAML's registration order.
#
# Transcribing the table rather than writing out the spellings is the point.
# Hand-writing `no`, `off`, `yes`, `on` into the boolean list is how this reader
# came to resolve `true` and `false` and miss the other four: the domain was
# enumerated by spelling rather than derived, so anything not spelled out
# silently stayed a string.
#
# The two remaining resolvers are here even though they are not types a
# workflow should carry, because PyYAML has no safe constructor for either on a
# scalar: `build-mode: <<` and `build-mode: =` are both a ConstructorError, not
# the strings `<<` and `=`. Marking them non-strings keeps a document no parser
# accepts out of the usable-value set rather than reading it as a string.
#
# A resolved type here is a non-string, so the usable-value check asks what the
# value became rather than what this reader happened to keep.
IMPLICIT_TYPES = (
    (r"(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON"
     r"|off|Off|OFF)$", "yYnNtTfFoO", "bool"),
    (r"(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?"
     r"|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?"
     r"|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*"
     r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$", "-+0123456789.", "float"),
    (r"(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)"
     r"|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$",
     "-+0123456789", "int"),
    (r"(?:<<)$", "<", "merge"),
    (r"(?:~|null|Null|NULL|)$", "~nN", "null"),
    (r"(?:[0-9]{4}-[0-9]{2}-[0-9]{2}"
     r"|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}"
     r":[0-9]{2}:[0-9]{2}(?:\.[0-9]*)?"
     r"(?:[ \t]*(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?))?)$", "0123456789", "timestamp"),
    (r"(?:=)$", "=", "value"),
)
IMPLICIT = {}
for _pattern, _first, _type in IMPLICIT_TYPES:
    for _char in _first:
        IMPLICIT.setdefault(_char, []).append((re.compile(r"^" + _pattern), _type))


def resolve_plain(text):
    """The type a plain scalar resolves to, or the text itself when `str`."""
    for pattern, kind in IMPLICIT.get(text[:1], ()):
        if pattern.match(text):
            return Resolved(kind)
    return text


def strip_properties(text, raw):
    """The node content of `text` with its anchor and tag removed.

    A scalar's node properties may carry an anchor and a tag in EITHER order,
    and both precede the content -- PyYAML accepts `&a !!str |` and `!!str &a |`
    alike -- so they are stepped over in a loop rather than tested in one
    order.

    An anchor is metadata over a value this reader can read, so it is stepped
    over: `language: &l python` IS the language python, and holding the string
    `&l python` instead would be a false refusal of valid YAML. So is the
    string tag, decided by tag URI rather than by spelling.

    Any other tag can change the value's TYPE -- `!!binary` to bytes, `!!int
    '3'` to 3 -- so it is refused rather than interpreted.

    Returns (content, carried_a_tag). A property with NO content is not a
    value: PyYAML reads `include: &m` over a block sequence as that sequence,
    and `build-mode: &bm` alone as null. So an emptied content comes back as
    None -- "no value on this line", which is what lets a block follow --
    rather than as the empty string, which is a value and refuses the block.
    The caller checks the flag because PyYAML rejects a tagged node that turns
    out to be a mapping: `include: !!str` over a block is an error.
    """
    anchors = 0
    tagged = False
    while text[:1] in ("&", "!", "?"):
        if text[:1] == "?":
            # An indicator, so no plain scalar may begin with one; PyYAML
            # rejects `run: ? foo` outright.
            refuse(f"refusing `?` in value position, an indicator no plain "
                   f"scalar may begin with: {raw}")
        if text[:1] == "!":
            tagged = True
            if not tag_is_string(text.split()[0]):
                refuse(f"refusing a type-changing tag this reader does not "
                       f"model: {raw}")
        else:
            anchors += 1
            if anchors > 1:
                # PyYAML rejects `&a &b python`: one node carries at most one
                # anchor.
                refuse(f"a second anchor on one node, which YAML does not "
                       f"admit: {raw}")
        parts = text.split(None, 1)
        text = parts[1].strip() if len(parts) > 1 else ""
    return (text or None), tagged


class Resolved:
    """A plain scalar YAML resolves to a non-string type.

    Held as one sentinel for every implicit type, `null` included, and kept
    distinct from None because None already means "no value on this line, a
    block follows" to the parse loop below -- collapsing the two would let
    `build-mode:` adopt the lines after it. The usable-value check asks
    `isinstance(value, str)`, so every resolved type is rejected by
    construction and the family needs no spelling-by-spelling test.
    """

    def __init__(self, kind):
        self.kind = kind

    def __repr__(self):
        return f"<yaml {self.kind}>"


NULL = Resolved("null")


def strip_comment(raw):
    # The line without its trailing comment. `#` inside quotes, or with no
    # space before it, is a value character; `#` outside quotes after a space
    # opens a comment, as it does in YAML.
    quote = None
    for index, char in enumerate(raw):
        if quote is not None:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "#" and (index == 0 or raw[index - 1] == " "):
            return raw[:index].rstrip()
    return raw.rstrip()


def quoted_scalar(text):
    if text.startswith("'"):
        if not re.fullmatch(r"'(?:[^']|'')*'", text):
            refuse(f"unsupported single-quoted YAML scalar: {text}")
        return text[1:-1].replace("''", "'")
    if text.startswith('"'):
        if not re.fullmatch(r'"[^"\\]*"', text):
            refuse(f"unsupported double-quoted YAML escape: {text}")
        return text[1:-1]
    return text


if not path.is_file():
    refuse("the codeql workflow must exist")

# The block layout, walked line by line: every node's path is its own path plus
# its key, and a `- ` entry is keyed by its position under its parent.
nodes = {}
parents = [(-1, ())]
sequences = {}
tagged_nodes = set()
for raw in path.read_text().splitlines():
    line = strip_comment(raw)
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    lead = line[:len(line) - len(line.lstrip(" \t"))]
    if "\t" in lead:
        # YAML forbids a tab in indentation. This reader counts one as no
        # indentation at all, which would silently re-parent the line — and a
        # re-parented key is a different workflow, read without a word.
        refuse(f"tab-indented line, which YAML forbids and this reader would "
               f"count as no indentation: {raw}")
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
        if entry[:1] == "*":
            # An alias. Its referent is an anchor declared elsewhere in the
            # document and this reader resolves no aliases, so which entries it
            # contributes is a question it cannot answer.
            refuse(f"an alias in a block sequence, whose referent this reader "
                   f"cannot resolve: {raw}")
        # An anchor is metadata over the entry, not the entry itself: PyYAML
        # reads `- &m` followed by two keys as one mapping carrying both, so a
        # bare anchor continues with the entry's parent already pushed.
        entry, entry_tagged = strip_properties(entry, raw)
        if entry is None:
            if entry_tagged:
                # PyYAML rejects a tag on a node that is not a scalar:
                # `- !!str` over a mapping body is a ConstructorError.
                refuse(f"a tag with no content on a block sequence entry, which "
                       f"YAML does not admit: {raw}")
            continue
        if entry[:1] in ("|", ">"):
            # A block scalar as the whole entry, `- |` over a `language:` /
            # `build-mode:` body. No parent is pushed, so that body would be
            # walked as structure; refusing here names the block scalar rather
            # than blaming the matrix entry that follows it.
            refuse(f"refusing a block scalar this reader does not model: {raw}")
        # A block sequence usually holds mappings, but `paths-ignore:` and
        # `cron:` hold plain scalars. An entry is read as a scalar only when
        # it cannot be a mapping; an ambiguous one is refused, not guessed.
        if entry[:1] in ("'", '"') or ":" not in entry:
            nodes[parent] = quoted_scalar(entry)
            parents.pop()
            continue
    pair = re.fullmatch(r"([^:]+):(?:\s+(.*))?", entry)
    if not pair:
        refuse(f"expected explicit workflow mapping: {raw}")
    key, value = quoted_scalar(pair[1].strip()), pair[2]
    # Bound on every line, not only on the ones with a value: the parse loop is
    # one long-lived scope, so a flag set by `fail-fast: ! false` would still be
    # set when the next bare key is reached, and would tag THAT node.
    tagged = False
    if key == "<<":
        # A merge key. Which keys it contributes is a question this reader
        # cannot answer, and `<<` read as an ordinary key means a language
        # hidden behind a merge reads as a key that is merely present.
        refuse(f"a merge key, which this reader does not model: {raw}")
    if value is not None:
        value = value.strip()
        # Properties come off before anything below interprets the value, which is
        # what lets the block-scalar arm key on the FIRST character again:
        # `!!str |` has already become `|` by the time it is tested, and keying
        # on the last token instead would refuse `run: echo x >`, which PyYAML
        # accepts as an ordinary plain scalar.
        value, tagged = strip_properties(value, raw)
        if value is None:
            # A property with no content: no value on this line, so a block may
            # follow. The tag flag rides along to the check below, because
            # PyYAML rejects a tagged node that turns out to be a mapping.
            pass
        elif value[:1] in ("'", '"'):
            value = quoted_scalar(value)
        elif value[:1] == "*":
            # An alias. Its referent is declared elsewhere; this reader
            # resolves no aliases, so the value is a question it cannot answer.
            refuse(f"an alias in value position, whose referent this reader "
                   f"cannot resolve: {raw}")
        elif value[:1] in ("{", "["):
            # A flow collection. `{}` is an empty mapping and contributes no
            # keys, so `permissions: {}` is read exactly as a leaf; any other
            # one hides structure this reader cannot walk.
            if value != "{}":
                refuse(f"refusing a flow collection this reader does not model: {key}: {value}")
        elif value[:1] in ("|", ">"):
            # A block scalar, on the FIRST character because any tag or anchor
            # in front of it has already been stepped over above. Its header is
            # `|` or `>` with an optional indentation indicator and an optional
            # chomping indicator in either order, so every spelling is one of
            # `|`, `|-`, `|+`, `|2`, `|2-`, `>`, `>-`, `>+`, `>2`. No parent is
            # pushed, so the body that follows would be walked as structure:
            # the matrix, `init`'s `with:` and the analyze step's `category:`
            # can each be satisfied by inert text under a `run:`, and every
            # limb would read green over a workflow that analyses nothing.
            refuse(f"refusing a block scalar this reader does not model: {key}: {value}")
        elif re.search(r":(\s|$)", value):
            # Two mappings on one line, which PyYAML rejects as well --
            # `run: echo a: b` and `run: echo "a: b"` are both ScannerErrors,
            # so a plain scalar cannot carry `: ` in any case. A colon with NO
            # space after it is a value character and is NOT this shape:
            # PyYAML reads `language: python:3` as the language `python:3`,
            # and `1:30` as the sexagesimal integer 90.
            refuse(f"two mappings on one line, which this reader refuses to "
                   f"choose between: {raw}")
        else:
            # A plain scalar, and the one place YAML decides what a value
            # BECOMES without being told. Every implicit type resolves to a
            # non-string, so `no`, `off`, `1:30` and `.inf` are caught by the
            # family rather than by a spelling added one report at a time.
            value = resolve_plain(value)
        if isinstance(value, str):
            # Every `${{ … }}` in the value, not only a value that IS one: a
            # job name is `analyze (${{ matrix.language }})`, and normalising
            # only a wholly-expression value left the embedded spelling
            # unnormalised, which reddened a maintainer's tightened spacing.
            value = re.sub(r"\$\{\{.*?\}\}",
                           lambda m: "${{ " + m[0][3:-2].strip() + " }}", value)
    node = parent + (key,)
    if node in nodes:
        refuse(f"duplicate workflow key: {node}")
    nodes[node] = value
    if value is None:
        if tagged:
            tagged_nodes.add(node)
        parents.append((indent, node))


# A key with no value and no block under it is null, not an unfinished
# mapping: PyYAML reads `build-mode:` as None exactly as it reads
# `build-mode: null`. The parse loop above can only know that nothing
# followed, which is the same fact, so the two are settled here rather than
# in the assertion that reads them.
parents_of = {key[:length] for key in nodes for length in range(len(key))}
for key in [key for key, value in nodes.items()
            if value is None and key not in parents_of]:
    nodes[key] = NULL

# A tag whose node turned out to be a block. Whether a block followed is only
# knowable here, and PyYAML rejects it: `include: !!str` over a block sequence
# is a ConstructorError, not the sequence. An anchor carries no such claim, so
# `include: &m` over a sequence is left alone and reads as the sequence.
for key in tagged_nodes & parents_of:
    refuse(f"a tag on a node that is a block rather than a scalar, which YAML "
           f"does not admit: {'.'.join(key)}")


def block(*parts):
    # A path that must be a block, because what this case reads lives under it.
    node = ()
    for key in parts:
        node += (key,)
        if node not in nodes:
            refuse(f"the codeql workflow declares no {'.'.join(node)}")
        if nodes[node] is NULL:
            refuse(f"{'.'.join(node)} is a bare key, which YAML reads as null "
                   f"rather than as a block")
        if nodes[node] is not None:
            refuse(f"{'.'.join(node)} is written inline, not as a block")
    return node


def want(node, expected, why):
    actual = nodes.get(node, "<absent>")
    assert actual == expected, f"{'.'.join(node)} is {actual!r}, not {expected!r}: {why}"


# 1. include is a non-empty sequence and every entry is complete. Walked, not
# hard-coded: the matrix is expected to grow, and an entry that grows into
# itself incomplete is the regression this is here for.
include = block("jobs", "analyze", "strategy", "matrix", "include")
entries = sorted({node[len(include)] for node in nodes
                  if node[:len(include)] == include and len(node) == len(include) + 1})
assert entries, (
    "jobs.analyze.strategy.matrix.include declares no entries, so the job "
    f"analyses no language at all: {sorted(nodes)}")
for index in entries:
    held = sorted(node[len(include) + 1] for node in nodes
                  if node[:len(include) + 1] == include + (index,)
                  and len(node) == len(include) + 2)
    for key in ("language", "build-mode"):
        # Presence AND a usable value. An absent key, an empty one and a
        # YAML null all reach init the same way — `build-mode: ${{
        # matrix.build-mode }}` expands to nothing — so a presence-only
        # assertion, or one that asks the reader whether its own unresolved
        # scalar is non-empty, is a green over a matrix leg that dies on a
        # build-mode CodeQL refuses. NULL is that reader's answer for the four
        # spellings `null`, `Null`, `NULL` and `~`, and for a bare `key:`.
        value = nodes.get(include + (index, key))
        assert isinstance(value, str) and value.strip(), (
            f"matrix entry {index} declares no usable {key}: it holds {held} "
            f"with {value!r}, and init is handed an empty {key} for it")


# 2. python is one of the languages the entries name. The hand-held membership,
# for the reason the comment above records.
languages = {nodes[include + (index, "language")] for index in entries}
assert "python" in languages, (
    "no matrix entry declares `language: python`, so claim.py — the program "
    "that parses the untrusted comment body — is never analysed: the matrix "
    f"names {sorted(map(str, languages))}")


# 3. The value is consumed, not merely declared: the job is NAMED for the
# language it analyses, the init step analyses matrix.language, and the analyze
# step files it under that language's category. The job name is the first of
# the three and is the one that makes two matrix entries land as two checks
# rather than two runs of the same check, so a pin that left it out would
# break that silently while the comment above still claimed it.
#
# The job name is required to INTERPOLATE the expression rather than to equal a
# fixed string: `CodeQL (${{ matrix.language }})` names its check just as well,
# and a pin that reddened a cosmetic rewording would be a defect of its own.
job_name = nodes.get(("jobs", "analyze", "name"), "<absent>")
assert isinstance(job_name, str) and "${{ matrix.language }}" in job_name, (
    f"the analyze job is named {job_name!r}, which does not interpolate "
    f"matrix.language, so every matrix entry would answer to one check name "
    f"and none of them would land as its own check")

steps = block("jobs", "analyze", "steps")
step_names = sorted({node[len(steps)] for node in nodes
                     if node[:len(steps)] == steps and len(node) == len(steps) + 1})


def step_using(action):
    found = [index for index in step_names
             if str(nodes.get(steps + (index, "uses"), "")).startswith(
                 f"github/codeql-action/{action}@")]
    if len(found) != 1:
        refuse(f"expected exactly one github/codeql-action/{action} step, "
               f"found {len(found)}: the job would analyse or file nothing")
    return found[0]


init_with = block("jobs", "analyze", "steps", step_using("init"), "with")
analyze_with = block("jobs", "analyze", "steps", step_using("analyze"), "with")
want(init_with + ("languages",),
     "${{ matrix.language }}",
     "each matrix entry would otherwise reach the analysis of some default "
     "language set rather than its own")
want(analyze_with + ("category",),
     "/language:${{ matrix.language }}",
     "the SARIF would land with no category naming the language, so a run "
     "could not be found by the language it analysed")
PYCODEQL
}

# The suite, grouped by what it is about. #45, #50 and #51 are the branch;
# everything else predates it. The three long-body groups are the ones whose
# size arithmetic is worth knowing before changing: a reply crosses GitHub's
# 65,536-character limit at 32,713 carried digits, and an argument list dies at
# 131,072 bytes, which exactly 32,768 four-byte characters reach; the decline
# case posts `/claim ` plus 32,740 of them, and the reply quoting that line is
# 187 bytes of framing over and above the filler — 131,147 bytes, past the
# argument limit, with the body itself still 105 bytes under it.
cases=(
  # The body's shape: prose, not a command — and the one line that starts a
  # command word, which is an attempt.
  sentence url_mention_ends_quietly multiline interior_cr metacharacters
  whitespace_only blank_lines_around_command nbsp_noncommand
  em_space_noncommand unit_separator_noncommand ascii_control_trim
  word_start_on_later_line_declines_that_line topmost_command_word_wins
  command_word_needs_a_boundary cr_stripped_before_the_line_scan
  # The attempt line reaches two sinks -- the run log and the reply body --
  # and each sink's defect has its own pin: #73 neutralises the control
  # characters before both, #74 quotes the line in a code span the line
  # cannot close.
  control_chars_escaped_before_both_sinks backtick_line_quoted_in_an_unclosable_span
  claim_number_trailing_prose claim_number_next_line
  claim_uppercase_noncommand claim_number_attached
  # #50 and #51: the two replies a maximum-size body reaches.
  not_a_command_over_long not_a_command_bigger_than_an_argument
  claim_number_body_too_long_to_quote
  # #45: the mismatch refusal, its wording, and the ceiling that bounds it.
  claim_number_mismatch claim_number_mismatch_other_words
  claim_number_over_long claim_number_quoted_in_full
  claim_number_reply_length_bounded claim_number_ceiling_edge
  # The action itself.
  already_assigned trimmed_command claimed_by_others claimed_by_three
  claim_accepted claim_accepted_elsewhere claim_rejected
  claim_with_number claim_with_hash_number unclaim_with_number
  unclaim_not_assigned unclaim_one_of_two release_one_of_two
  closed_issue pull_request
  # Two claims racing for one issue: the tie, its settlement, and the refusals.
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
  malformed_snapshot missing_assignees bot_actor
  organization_actor mannequin_actor invalid_issue invalid_repository repository_query
  assignment_post_forbidden unclaim_delete_forbidden comment_forbidden
  # The stub itself: what it records, and what it refuses.
  stub_models_the_body_on_stdin stub_counts_characters_not_bytes
  # Who is commenting: the token's own account, and the identity lookup.
  token_commenter_declined
  token_commenter_declined_case_insensitive distinct_commenter_proceeds
  malformed_identity_snapshot identity_not_an_object
  identity_body_naming_the_refusal_proceeds
  identity_answer_missing_fails identity_answer_403_proceeds
  identity_answer_rate_limited_fails identity_answer_other_403_fails
  identity_answer_unrelated_refusal_fails identity_answer_silent_failure_fails
  identity_answer_unauthenticated_fails
  identity_answer_body_fallback_status_from_case_fails
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
  # The transport: gh's refusals, and a failure to reach it at all.
  read_transport_status
  # What the inputs are allowed to be.
  null_login_initial null_login_confirm null_assignee_initial null_assignee_confirm
  missing_login_initial missing_login_confirm
  cap_disabled_no_search_call cap_unlimited_role_skips_counting cap_under_limit_proceeds
  cap_refuses_at_limit cap_zero_forbids_role cap_minus_one_entry_is_unlimited
  cap_triage_role cap_custom_role_folds_to_base
  cap_whitespace_around_entries_accepted cap_tab_after_comma_accepted
  cap_malformed_value_negative_cap cap_malformed_value_unknown_role
  cap_malformed_value_duplicate_key cap_malformed_value_non_integer
  cap_malformed_value_empty_entry cap_space_inside_entry_refused
  cap_malformed_role_snapshot
  cap_role_snapshot_not_an_object cap_custom_role_base_unreadable
  cap_role_lookup_failure cap_malformed_search_response cap_search_transport_failure
  # Claim expiry: the input grammar, the lazy default, and both expiry
  # paths (takeover and privileged release) on every side of their
  # boundaries.
  expire_malformed_zero expire_malformed_below_minus_one expire_malformed_unit_suffix
  expire_malformed_not_a_number expire_malformed_empty
  expire_disabled_no_timeline_call expire_fresh_claim_no_expiry_calls
  expire_takeover_inside_window expire_takeover_boundary_day expire_takeover_expired
  expire_takeover_multiple_expired expire_takeover_cap_zero expire_takeover_cap_reached
  expire_takeover_cap_under_proceeds
  expire_takeover_proof_fails expire_takeover_age_unreadable expire_takeover_mixed_created_at
  expire_takeover_post_declined
  expire_release_read_role_refused expire_release_triage_role_refused
  expire_release_write_role expire_release_maintain_role expire_release_admin_role
  expire_release_mixed_created_at
  expire_release_write_role_inside_window expire_release_proof_fails
  expire_release_integration_token expire_release_multiple_expired
  expire_release_no_assignees
  # The manifests this action is, and the literals it keeps in more than one
  # file: the replies the README quotes (held against claim.py) and the
  # install block's job condition (held against claim.yml — actionlint.yml's
  # pin step compares the pins alone, so no other gate sees this pair drift).
action_contract pr_gate_contract readme_quoted_replies
  readme_install_condition_matches_claim_yml codeql_matrix_covers_python
  # Issue 64: a green head must carry what main holds, or it vouches for nothing.
  gate_freshness_step_is_wired gate_paths_derived_from_workflows
  gate_derivation_handles_every_spelling
  gate_derivation_refuses_each_unmodelled_shape
  gate_merge_commit_is_reported_honestly
  gate_base_freshness_states
  # Issue 90: a workflow's name is a scope only with the ci type. The wiring
  # is the primary pin -- the rehearsal beside it extracts whatever the step
  # body says -- and the states are rehearsed by executing the step the way
  # the runner hands it to bash, against a real fixture.
  commit_scope_step_is_wired commit_scope_states)
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
