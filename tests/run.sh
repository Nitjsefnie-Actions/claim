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
export GH_TOKEN CLAIM_REPOSITORY CLAIM_ISSUE CLAIM_ACTOR CLAIM_ACTOR_TYPE GH_CASE GH_IDENTITY CLAIM_MAX_CLAIMS CLAIM_EXPIRE

reset_case() {
  GH_TOKEN=test-token
  CLAIM_REPOSITORY=owner/project
  CLAIM_ISSUE=7
  CLAIM_ACTOR=octo-claimant
  CLAIM_ACTOR_TYPE=User
  CLAIM_MAX_CLAIMS=-1
  CLAIM_EXPIRE=-1
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
  CLAIM_BODY="$body" python3 "$ROOT/claim.py" > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
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
# environment will hold for CLAIM_BODY, 75 over what one argument will hold for the
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
  if [[ -z $posted || $posted == *[!0-9]* ]]; then
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

# The disabled default costs nothing: with CLAIM_MAX_CLAIMS=-1 the exact
# claim_accepted sequence runs, and the expected/recorded diff IS the
# no-role-lookup and no-search assertion — the stub answers the role
# endpoint and search only from the sequence, so any extra call fails the
# case here.
cap_disabled_no_search_call() {
  body=/claim
  CLAIM_MAX_CLAIMS=-1
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
  CLAIM_MAX_CLAIMS='read=2, write=6'
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
  CLAIM_MAX_CLAIMS='read=2, write=6'
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
  CLAIM_MAX_CLAIMS='read=2, write=6'
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
  CLAIM_MAX_CLAIMS='read=0, write=6'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant claiming is disabled for your role (read) in this repository. A maintainer can still assign you by hand.' --silent
  run_claim 0
}

# An explicit -1 entry leaves that role unlimited: counted nowhere, assigned
# as usual.
cap_minus_one_entry_is_unlimited() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2, admin=-1'
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
  CLAIM_MAX_CLAIMS='read=2, triage=4'
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
  CLAIM_MAX_CLAIMS='read=2, write=6'
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
  CLAIM_MAX_CLAIMS=' read=2 , write=6 '
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
  CLAIM_MAX_CLAIMS=$'read=2,\twrite=6'
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
  CLAIM_MAX_CLAIMS='read=-2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

cap_malformed_value_unknown_role() {
  body=/claim
  CLAIM_MAX_CLAIMS='maintainer=3'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

cap_malformed_value_duplicate_key() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=1, read=2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# A cap that is not an integer never reaches the int() conversion: the entry
# grammar refuses it first, and a grammar loosened enough to pass read=two
# would convert it at int() with a different, unhelpful message.
cap_malformed_value_non_integer() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=two'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# An entry that strips to nothing — the trailing comma's empty tail — fails
# the entry grammar like any other shape it cannot parse.
cap_malformed_value_empty_entry() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2,'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# Whitespace inside an entry is the one place stripping does not reach:
# read =2 keeps its space and fails the grammar like any other value
# the run cannot read.
cap_space_inside_entry_refused() {
  body=/claim
  CLAIM_MAX_CLAIMS='read =2'
  expected_error='invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs'
  run_claim 1
}

# A role response without role_name is a snapshot this run cannot read:
# proceeding would compare the cap against a role that was never
# established. No comment, no search.
cap_malformed_role_snapshot() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2'
  expected_error='role snapshot must contain a role_name string'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read"}' api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

# The other unreadable role shape: the payload is not an object at all, and
# the same refusal fires rather than a role being read out of it.
cap_role_snapshot_not_an_object() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2'
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
  CLAIM_MAX_CLAIMS='read=2'
  expected_error='role snapshot must give a readable role'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"role_name":"release-manager","permission":"none"}' api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

# A role lookup transport failure fails the run with gh's own exit status,
# before any comment or search, exactly like the other transport failures.
cap_role_lookup_failure() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2'
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
  CLAIM_MAX_CLAIMS='read=2'
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
  CLAIM_MAX_CLAIMS='read=2'
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
  CLAIM_EXPIRE=0
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_below_minus_one() {
  body=/claim
  CLAIM_EXPIRE=-2
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_unit_suffix() {
  body=/claim
  CLAIM_EXPIRE=7d
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_not_a_number() {
  body=/claim
  CLAIM_EXPIRE=abc
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

expire_malformed_empty() {
  body=/claim
  CLAIM_EXPIRE=
  expected_error='invalid expire: expected -1 or a positive integer of days'
  run_claim 1
}

# The disabled default costs nothing even on a claimed issue: no events
# call, no takeover machinery — the empty events expectation IS the
# assertion, because the stub fails loudly on any call the case never
# expected.
expire_disabled_no_timeline_call() {
  body=/claim
  CLAIM_EXPIRE=-1
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
  CLAIM_EXPIRE=7
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

# Seven days minus an hour: inside the window, today's refusal verbatim.
expire_takeover_inside_window() {
  body=/claim
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
  CLAIM_MAX_CLAIMS='read=0'
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
  CLAIM_EXPIRE=7
  CLAIM_MAX_CLAIMS='read=1'
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
  CLAIM_EXPIRE=7
  CLAIM_MAX_CLAIMS='read=2'
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"read"}' api repos/owner/project/collaborators/octo-maintainer/permission
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

expire_release_triage_role_refused() {
  body=/release
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"read","role_name":"triage"}' api repos/owner/project/collaborators/octo-maintainer/permission
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-maintainer you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

# write, maintain and admin may release someone else's expired claim.
expire_release_write_role() {
  body=/release
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"write","role_name":"write"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

expire_release_maintain_role() {
  body=/release
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '{"permission":"maintain","role_name":"maintain"}' api repos/owner/project/collaborators/octo-maintainer/permission
  expect_gh "$(expected_timeline claim-token-account '800|alice|8')" api --paginate --slurp 'repos/owner/project/issues/7/events?per_page=100'
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=alice' --silent
  expect_gh '' api repos/owner/project/issues/7/comments --input - "body=@octo-maintainer has released @alice's expired claim (held 8 day(s))." --silent
  run_claim 0 $'released expired claim of alice (held 8 day(s))\n'
}

expire_release_admin_role() {
  body=/release
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=octo-maintainer
  CLAIM_EXPIRE=7
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
  CLAIM_ACTOR=yuki-dev
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
  CLAIM_ACTOR=alice
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
  CLAIM_ACTOR=yuki-dev
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
  CLAIM_ACTOR=octo-claimant
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
  CLAIM_ACTOR=yuki-dev
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
  CLAIM_ACTOR=river-helper
  CLAIM_REPOSITORY=other-team/widget.tools
  CLAIM_ISSUE=42
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
  CLAIM_ISSUE=42
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
  if [[ -z $short_len || $short_len == *[!0-9]* ||
          -z $long_len || $long_len == *[!0-9]* ]]; then
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
  CLAIM_ACTOR=river-helper
  CLAIM_REPOSITORY=other-team/widget.tools
  CLAIM_ISSUE=42
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
  CLAIM_ACTOR_TYPE=Bot
  run_claim 0 $'not a user: Bot\n'
}

organization_actor() {
  body=/claim
  CLAIM_ACTOR_TYPE=Organization
  run_claim 0 $'not a user: Organization\n'
}

mannequin_actor() {
  body=/claim
  CLAIM_ACTOR_TYPE=Mannequin
  run_claim 0 $'not a user: Mannequin\n'
}

empty_actor_type() {
  body=/claim
  CLAIM_ACTOR_TYPE=
  expected_error='invalid actor-type: expected a nonempty account type'
  run_claim 1
}

multiline_actor_type() {
  body=/claim
  CLAIM_ACTOR_TYPE=$'Bot\nUser'
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
  CLAIM_ACTOR=Octo-Claimant
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
  CLAIM_ACTOR_TYPE=Bot
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
  CLAIM_ISSUE='7/comments?x=1'
  expected_error='invalid issue: expected digits'
  run_claim 1
}

invalid_repository() {
  body=/claim
  CLAIM_REPOSITORY='owner/project/issues'
  expected_error='invalid repository: expected owner/name'
  run_claim 1
}

repository_query() {
  body=/claim
  CLAIM_REPOSITORY='owner/project?x=1'
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

deleted_issue() {
  body=/claim
  expected_error='gh: This issue was deleted (HTTP 410)'
  expect_gh_failure 1 "$expected_error" api repos/owner/project/issues/7
  run_claim 0 $'issue was deleted; nothing was claimed\n'
}

missing_issue_still_fails() {
  body=/claim
  expected_error='gh: Not Found (HTTP 404)'
  expect_gh_failure 1 "$expected_error" api repos/owner/project/issues/7
  run_claim 1
}

unrelated_gone_still_fails() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2'
  expected_error='gh: Gone (HTTP 410)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 1 "$expected_error" \
    api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 1
}

deleted_issue_after_read() {
  body=/claim
  CLAIM_MAX_CLAIMS='read=2'
  expected_error='gh: This issue was deleted (HTTP 410)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 1 "$expected_error" \
    api repos/owner/project/collaborators/octo-claimant/permission
  run_claim 0 $'issue was deleted; nothing was claimed\n'
}

deleted_issue_unclaim() {
  body=/unclaim
  expected_error='gh: This issue was deleted (HTTP 410)'
  expect_gh_failure 1 "$expected_error" api repos/owner/project/issues/7
  run_claim 0 $'issue was deleted; nothing was claimed\n'
}

deleted_issue_release() {
  body=/release
  expected_error='gh: This issue was deleted (HTTP 410)'
  expect_gh_failure 1 "$expected_error" api repos/owner/project/issues/7
  run_claim 0 $'issue was deleted; nothing was claimed\n'
}

# Issue 159: one transient GitHub failure — an HTTP 503, a 429, a connection
# that never completed — used to fail the run on its first attempt, with no
# retry and no reply. The retried-then-succeeds rows below pin the retry on
# the two calls a run makes first (the identity lookup and the issue read)
# against exhausted rows beside them, and a warning arriving beside a healthy
# answer is pinned too, because stderr is now captured in order to be
# classified and capture must not swallow it. The decisive direction is NOT
# re-pinned here: every expect_gh_failure row and every identity failure row
# above is already one-response-then-loud-stub-failure, which is exactly what
# decisiveness looks like, and none of them moves.
#
# The two marked classes each get two spellings — a 503 and a 500; a Post
# and a Get transport failure — so a classifier narrowed to the first
# spelling it saw reddens exactly the row the second spelling carries.
# These rows run the real backoff sleeps, roughly twenty seconds added to
# every suite run across them; they stay real because an injectable wait
# would test the injection point, not the wait.
identity_503_retried_then_succeeds() {
  local result=0
  # GitHub's own 503 message line, as gh writes it to stderr.
  local fifty3='gh: No server is currently available to service your request. Sorry about that. Please try resubmitting your request and contact us if the problem persists. (HTTP 503)'
  body=/claim
  # The identity answer as a sequence: a 503 on the first attempt, the
  # account on the second. The empty body file IS the sequence switch as
  # well as the answer: it states a probe that failed and wrote nothing to
  # stdout, and the stub's sequence mode is switched on by
  # identity.response.1 existing at all.
  : > "$GH_CASE/identity.response.1"
  printf '%s\n' "$fifty3" > "$GH_CASE/identity.response.1.stderr"
  printf '1\n' > "$GH_CASE/identity.response.1.status"
  printf '%s\n' '{"login":"octo-claimant","type":"User"}' > "$GH_CASE/identity.response.2"
  run_claim 0 "commenter is the token's own account: octo-claimant"$'\n' || result=1
  # The raw call set is the retry's pin: exactly two identity calls, no
  # ordinary call. A run that gave up after the first answer stops at one
  # line; a run that retried anything else adds a line it never made.
  printf '%s\n' '["api","user"]' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

identity_503_exhausts_attempts() {
  local result=0
  local fifty3='gh: No server is currently available to service your request. Sorry about that. Please try resubmitting your request and contact us if the problem persists. (HTTP 503)'
  body=/claim
  # The static answer serves the same 503 on every attempt — there is no
  # sequence here — so the retries run out against one persistent outage,
  # and the run fails naming the attempts it waited through.
  printf '%s\n' "$fifty3" > "$GH_CASE/identity.response.stderr"
  printf '1\n' > "$GH_CASE/identity.response.status"
  expected_error="cannot establish which account this token posts as: the /user lookup failed for a reason other than the documented installation-token refusal, after 3 attempts, and reported: $fifty3"
  run_claim 1 || result=1
  # Three identity calls and nothing else: the bound is exactly GH_ATTEMPTS.
  printf '%s\n' '["api","user"]' '["api","user"]' '["api","user"]' > "$GH_CASE/expected.calls"
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

snapshot_503_retried() {
  local result=0
  local fifty3='gh: No server is currently available to service your request. Sorry about that. Please try resubmitting your request and contact us if the problem persists. (HTTP 503)'
  body=/claim
  # The ordinary sequence serves the retry: the first read answers 503, the
  # second answers the issue, and the run carries on to the reply an
  # already-claimed issue gets.
  expect_gh_failure 1 "$fifty3" api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  # The raw call set gains the repeated identical line for the retried read:
  # the sequence in expected.jsonl already carries both reads, so the pin is
  # the identity line on top of it.
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

snapshot_503_exhausts() {
  local fifty3='gh: No server is currently available to service your request. Sorry about that. Please try resubmitting your request and contact us if the problem persists. (HTTP 503)'
  body=/claim
  # The same 503 on every attempt: three ordinals, one shape. A run that
  # retried forever would hit exit 91 on a fourth call instead of failing
  # with the three attempts named.
  expect_gh_failure 1 "$fifty3" api repos/owner/project/issues/7
  expect_gh_failure 1 "$fifty3" api repos/owner/project/issues/7
  expect_gh_failure 1 "$fifty3" api repos/owner/project/issues/7
  # gh's own words pass through, then the one new line naming the attempts.
  expected_error=$fifty3$'\n'"gh api repos/owner/project/issues/7 failed after 3 attempts"
  run_claim 1
}

transport_error_retried() {
  body=/claim
  # No `(HTTP NNN)` marker at all: a dropped connection is reported by gh as
  # METHOD "url": cause, and that unmarked shape is what gets retried here.
  expect_gh_failure 1 'gh: Post "https://api.github.com/repos/owner/project/issues/7": dial tcp 140.82.121.6:443: connect: connection refused' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

rate_limit_429_retried() {
  body=/claim
  # 429 is GitHub's throttling answer and is retried, where the 403
  # rate-limit row in the identity table stays decisive: it is the marker
  # the classifier reads, not the words.
  expect_gh_failure 1 'gh: You have exceeded a secondary rate limit and have been temporarily blocked from content creation. Please retry your request again later. (HTTP 429)' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

status_500_retried() {
  local result=0
  body=/claim
  # A second 5xx spelling: the marker arm reads the whole 5xx class, not
  # the 503 the row above carries, so this pin is the (HTTP 500) form —
  # a classifier narrowed to the first spelling seen would classify this
  # one decisive and stop here.
  expect_gh_failure 1 'gh: Server Error (HTTP 500)' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

transport_get_error_retried() {
  local result=0
  body=/claim
  # The transport arm's method is a wildcard, not the Post the row above
  # carries: Go renders the method as sent, so the Get spelling of the same
  # never-completed-connection shape must retry too.
  expect_gh_failure 1 'gh: Get "https://api.github.com/repos/owner/project/issues/7": dial tcp 140.82.121.6:443: i/o timeout' api repos/owner/project/issues/7
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  {
    printf '%s\n' '["api","user"]'
    cat "$GH_CASE/expected.jsonl"
  } > "$GH_CASE/expected.calls"
  run_claim 0 || result=1
  if ! diff -u "$GH_CASE/expected.calls" "$GH_CASE/calls.jsonl"; then result=1; fi
  return "$result"
}

snapshot_warning_on_success_reaches_the_log() {
  body=/claim
  # A 200 that carries a warning on stderr anyway: the answer is healthy,
  # the run proceeds to the reply, and the warning still reaches the log —
  # stderr is captured now so a failure can be classified, and capture must
  # not swallow what gh wrote beside a healthy answer.
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  printf '%s\n' 'gh: the API answered 200 with a deprecation warning' > "$GH_CASE/response.1.stderr"
  expect_gh '' api repos/owner/project/issues/7/comments --input - 'body=@octo-claimant you already have this one.' --silent
  expected_error='gh: the API answered 200 with a deprecation warning'
  run_claim 0
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

# --- automatic coverage-floor ratchet: real command, observable data --------
# Comparing to the floor raises inside the hysteresis; a zero gap reds the
# first dip after a raise. Drive those branches as subprocesses
# so a source-text pin cannot stay green while the operator changes.
ratchet_case() {
  python3 - "$ROOT" "$GH_CASE" "$1" <<'PYRATCHET'
from pathlib import Path
from decimal import Decimal
import json
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:3])
case = sys.argv[3]
record = {
    "schema_version": 1,
    "coverage": {"python": {
        "floor": 94.7, "measured": 96.2, "cell": "ubuntu-latest"}},
}
thresholds = scratch / "thresholds.json"
out = scratch / "not-created"
measured = "97.8"
expected_floor = Decimal("96.3")
refused = False
if case == "equal":
    measured = "96.2"
elif case == "lower":
    measured = "95.9"
elif case == "within_hysteresis":
    measured = "97.6"
elif case == "below_boundary":
    measured = "97.69999999999999"
elif case == "boundary":
    measured = "97.7"
elif case == "decimal_raise":
    measured = "97.71"
    expected_floor = Decimal("96.21")
elif case == "recorded_floor_wins":
    # A record whose floor sits above measured - 1.5 (only a hand edit
    # produces one): measuring 96.0 stages the recorded floor, not 94.5.
    record["coverage"]["python"]["floor"] = 96.0
    record["coverage"]["python"]["measured"] = 94.4
    measured = "96.0"
    expected_floor = Decimal("96.0")
elif case == "malformed":
    refused = True
elif case.startswith("measured:"):
    measured = case.split(":", 1)[1]
    refused = True
elif case == "schema":
    record["schema_version"] = 2
    refused = True
elif case == "missing_schema":
    del record["schema_version"]
    refused = True
elif case == "boolean_schema":
    record["schema_version"] = True
    refused = True
elif case == "cell":
    record["coverage"]["python"]["cell"] = "macos-latest"
    refused = True
elif case.startswith("missing:"):
    del record["coverage"]["python"][case.split(":", 1)[1]]
    refused = True
elif case.startswith("invalid:"):
    field, value = case.split(":")[1:]
    record["coverage"]["python"][field] = json.loads(value)
    refused = True
elif case != "better":
    raise AssertionError(f"unmodelled ratchet case: {case}")
thresholds.write_text("{broken" if case == "malformed" else json.dumps(record))
before = thresholds.read_bytes()
result = subprocess.run(
    ["python3", str(root / ".github/scripts/ratchet_thresholds.py"),
     f"--measured={measured}", "--thresholds", str(thresholds), "--out-dir", str(out)],
    check=False, capture_output=True, text=True)
assert thresholds.read_bytes() == before, "the measuring script edited the input record"
if refused:
    assert result.returncode != 0, f"{case}: invalid input accepted: {result.stdout}"
    assert str(thresholds) in result.stderr, f"{case}: refusal did not name {thresholds}"
    assert not out.exists(), f"{case}: refusal staged data"
else:
    assert result.returncode == 0, f"{case}: exit {result.returncode}: {result.stderr}"
    assert not result.stderr, result.stderr
    assert len(result.stdout.splitlines()) == 1, "expected one decision line"
    if case in ("better", "decimal_raise", "recorded_floor_wins"):
        assert out.is_dir(), "gain above the hysteresis staged no record"
        assert sorted(p.name for p in out.iterdir()) == ["ci-thresholds.json"]
        staged = out / "ci-thresholds.json"
        assert json.loads(staged.read_text(), parse_float=Decimal) == {
            "schema_version": 1,
            "coverage": {"python": {
                "floor": expected_floor, "measured": Decimal(measured),
                "cell": "ubuntu-latest"}},
        }, "the calibration gap, exact measurement or record metadata is wrong"
        assert staged.read_text() == """{
  "schema_version": 1,
  "coverage": {
    "python": {
      "floor": FLOOR,
      "measured": MEASURED,
      "cell": "ubuntu-latest"
    }
  }
}
""".replace("FLOOR", str(expected_floor)).replace("MEASURED", measured), \
            "staged JSON does not use the committed two-space layout"
    else:
        assert not out.exists(), f"{case}: no raise justified, but the out-dir was created"
PYRATCHET
}

ratchet_above_hysteresis_keeps_calibration_gap() { ratchet_case better; }
ratchet_equal_writes_nothing() { ratchet_case equal; }
ratchet_lower_never_loosens() { ratchet_case lower; }
ratchet_within_hysteresis_writes_nothing() { ratchet_case within_hysteresis; }
ratchet_below_hysteresis_boundary_writes_nothing() { ratchet_case below_boundary; }
ratchet_exact_hysteresis_boundary_writes_nothing() { ratchet_case boundary; }
ratchet_raise_uses_decimal_values() { ratchet_case decimal_raise; }
ratchet_recorded_floor_wins() { ratchet_case recorded_floor_wins; }
ratchet_refuses_malformed_json() { ratchet_case malformed; }
ratchet_refuses_non_numeric_measurement() { ratchet_case measured:garbage; }
ratchet_refuses_non_finite_measurement() {
  local value
  for value in NaN inf -inf; do
    ratchet_case "measured:$value" || return 1
  done
}
ratchet_refuses_schema() { ratchet_case schema; }
ratchet_refuses_missing_or_boolean_schema() {
  ratchet_case missing_schema && ratchet_case boolean_schema
}
ratchet_refuses_cell() { ratchet_case cell; }
ratchet_refuses_missing_fields() {
  local field
  for field in floor measured cell; do
    ratchet_case "missing:$field" || return 1
  done
}
ratchet_refuses_invalid_record_numbers() {
  local field value
  for field in floor measured; do
    for value in '"96.2"' null true NaN Infinity; do
      ratchet_case "invalid:$field:$value" || return 1
    done
  done
}

# A fetched module must never reach a validator beside the key. The fixture
# also poisons the runner cwd, so isolation remains pinned independently of
# bare Git plumbing. Only authentication is doubled; Git and validators run.
ratchet_push_excludes_fetched_code() {
  python3 - "$ROOT" "$GH_CASE" <<'PYPUSHBOUNDARY'
from pathlib import Path
import json
import os
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:3])
workflow = (root / ".github/workflows/ratchet-push.yml").read_text().splitlines()
name = "      - name: Push the tightened record to main"
anchors = [i for i, line in enumerate(workflow) if line == name]
assert len(anchors) == 1, "the named ratchet push step is missing or ambiguous"
start = anchors[0] + 1
stop = next((i for i in range(start, len(workflow))
             if workflow[i].strip() and not workflow[i].lstrip().startswith("#")
             and len(workflow[i]) - len(workflow[i].lstrip()) <= 6), len(workflow))
runs = [i for i in range(start, stop) if workflow[i] == "        run: |"]
assert len(runs) == 1, "the push step must carry exactly one literal shell block"
body = workflow[runs[0] + 1:stop]
assert all(not line.strip() or line.startswith("          ") for line in body)
script = "\n".join(line[10:] for line in body) + "\n"
# The standard SSH directory is redirected into this fixture alone. These
# three authentication doubles start no process and contact no SSH server.
script = script.replace("~/.ssh", '\"$PROBE_SSH/.ssh\"')
auth = """ssh-agent() { printf 'SSH_AGENT_PID=99999999; export SSH_AGENT_PID;\\n'; }
ssh-add() { cat "$1" >/dev/null; }
kill() { :; }
"""
poison = ("import os\n"
          "open(os.environ['SHADOW_SENTINEL'], 'w').write("
          "str(bool(os.environ.get('CLAIM_MASTER_PUSH_DEPLOY_KEY'))))\n"
          "raise RuntimeError('fetched json.py executed beside dummy deploy key')\n")

def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args],
                          check=True, capture_output=True, text=True).stdout.strip()

for mode in ("thresholds", "missing-thresholds", "absent", "moved-source",
             "moved-sibling", "moved-own-thresholds"):
    folder = scratch / mode
    source = folder / "source"
    source.mkdir(parents=True)
    (source / ".github").mkdir()
    thresholds = {"schema_version": 1, "coverage": {"python": {
        "floor": 96.2, "measured": 96.2, "cell": "ubuntu-latest"}}}
    # Multi-line JSON keeps any three-way merge line-shaped: a one-line file
    # rewrites itself whole, so every movement merges as a conflict.
    (source / ".github/ci-thresholds.json").write_text(json.dumps(thresholds, indent=2) + "\n")
    (source / "json.py").write_text(poison)
    git(source, "init", "-q", "-b", "main")
    # Fixture commits must not depend on the runner's global Git identity.
    git(source, "config", "user.name", "fixture")
    git(source, "config", "user.email", "fixture@example.invalid")
    git(source, "add", ".github/ci-thresholds.json", "json.py")
    git(source, "commit", "-q", "-m", "local ratchet fixture")
    base = git(source, "rev-parse", "HEAD")
    if mode.startswith("moved-"):
        # The gate measured at base; main then moved before the push run
        # fetched it, the window the issue describes. The move is committed
        # before the bare clone, so the remote's main already carries it.
        if mode == "moved-source":
            # A tracked path other than the thresholds file moving is the
            # defect: the staged data no longer describes main.
            poisoned = (source / "json.py").read_text()
            (source / "json.py").write_text(poisoned + "x = 1\n")
            git(source, "add", "json.py")
        elif mode == "moved-sibling":
            # Another gate's records file is ordinary tree movement here.
            (source / ".github/comment-share.json").write_text('{"a.py": [40, 100]}\n')
            git(source, "add", ".github/comment-share.json")
        else:
            # Only the thresholds file itself moved: the merge must land the
            # raise beside main's move.
            grown_thresholds = {"schema_version": 1, "coverage": {"python": {
                "floor": 96.2, "measured": 96.2, "cell": "ubuntu-latest"},
                "node": {"floor": 88.0, "measured": 88.0, "cell": "ubuntu-latest"}}}
            (source / ".github/ci-thresholds.json").write_text(
                json.dumps(grown_thresholds, indent=2) + "\n")
            git(source, "add", ".github/ci-thresholds.json")
        git(source, "commit", "-q", "-m", "main moved under the measured tree")
        moved = git(source, "rev-parse", "HEAD")
    origin = folder / "origin.git"
    git(source, "clone", "--quiet", "--bare", str(source), str(origin))
    runner = folder / "runner"
    runner.mkdir()
    (runner / "json.py").write_text(poison)
    thresholds_selected = mode != "absent"
    if thresholds_selected:
        data = runner / "ratchet-data"
        data.mkdir()
        (data / "base.txt").write_text(base + "\n")
        if not mode.startswith("missing-"):
            raised = {"schema_version": 1, "coverage": {"python": {
                "floor": 96.4, "measured": 96.4, "cell": "ubuntu-latest"}}}
            (data / "ci-thresholds.json").write_text(json.dumps(raised, indent=2) + "\n")
    bin_dir = folder / "bin"
    bin_dir.mkdir()
    ssh = bin_dir / "ssh"
    ssh.write_text("#!/bin/sh\nexit 97\n")
    ssh.chmod(0o755)
    env = dict(os.environ, RUNNER_TEMP=str(runner), PROBE_SSH=str(folder / "ssh"),
               CLAIM_MASTER_PUSH_DEPLOY_KEY="dummy-key-only", CLAIM_REPO="local/fixture",
               CLAIM_RATCHET_SELECTED=str(thresholds_selected).lower(),
               GITHUB_STEP_SUMMARY=str(folder / "summary"),
               SHADOW_SENTINEL=str(folder / "executed"),
               PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0=f"url.{origin}.insteadOf",
               GIT_CONFIG_VALUE_0="git@github.com:local/fixture.git",
               PYTHONPATH=str(source))
    # Prove the sentinel's import oracle is live without touching a real key.
    control_env = dict(env, SHADOW_SENTINEL=str(folder / "control-executed"))
    control = subprocess.run(["python3", "-B", "-c", "import json"], cwd=source,
                             env=control_env, check=False, capture_output=True, text=True)
    assert control.returncode != 0 and (folder / "control-executed").read_text() == "True"
    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", auth + script],
                            cwd=folder, env=env, check=False, capture_output=True, text=True)
    assert not (folder / "executed").exists(), f"{mode}: planted json.py executed"
    expected_status = 1 if mode.startswith("missing-") else 0
    assert result.returncode == expected_status, (mode, result.stdout, result.stderr)
    tip = git(origin, "rev-parse", "main")
    if mode.startswith("missing-"):
        assert "artifact ratchet-push is missing ci-thresholds.json" in result.stderr, result.stderr
        assert tip == base, f"{mode}: malformed handoff published a commit"
    else:
        bare = runner / "ratchet-repo"
        assert git(bare, "rev-parse", "--is-bare-repository") == "true"
        assert not (bare / "json.py").exists(), "fetched source was materialized"
        if mode.startswith("moved-"):
            assert tip != base, f"{mode}: the move never reached the remote"
            summary = folder / "summary"
            if mode == "moved-own-thresholds":
                # Only the thresholds file itself moved, so the run still
                # publishes on top of main's move: the positive control
                # against a check that over-drops.
                assert tip != moved, f"{mode}: an own-file move dropped a clean merge"
                actual = json.loads(git(origin, "show", "main:.github/ci-thresholds.json"))
                assert actual["coverage"]["python"]["floor"] == 96.4, actual
                assert actual["coverage"]["node"]["floor"] == 88.0, actual
                assert not summary.exists() or "Dropped" not in summary.read_text()
            else:
                # A path other than the thresholds file moved: the staged
                # data is dropped, the issue's defect.
                assert tip == moved, f"{mode}: stale data was published"
                assert summary.exists() and "Dropped: main moved under the measured tree" \
                    in summary.read_text(), f"{mode}: the drop left no summary"
        else:
            assert (tip != base) == (mode != "absent"), f"{mode}: wrong publication outcome"
            actual = json.loads(git(origin, "show", "main:.github/ci-thresholds.json"))
            assert actual["coverage"]["python"]["floor"] == (96.4 if thresholds_selected else 96.2)
    if mode in ("thresholds", "moved-own-thresholds"):
        subject = git(origin, "log", "-1", "--format=%s", "main")
        assert subject == "chore(ratchet): raise the coverage floor (automated)", subject
    print(f"  {mode}: exit {result.returncode}; shadow absent; publication verified")
PYPUSHBOUNDARY
}
# The step is what makes the check a required status context rather than a
# script nobody runs. Deleting it has to red this suite: the check would still
# be here, still correct, and would never once run. The pin holds that the step
# exists, runs the script, and sits after the checkout and before the lint.
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
# this pin cannot drift from the set of jobs it is protecting. The `push:`
# trigger gets the opposite polarity because a filter there fails silently in
# the other direction: a `paths:` allow-list stops the gate running on main
# after any unrelated change, and no pull request ever blocks to say so, while
# a `paths-ignore:` deny-list merely skips a documentation-only push. So a
# `paths-ignore:` key -- or no path filter at all -- is fine on push, and a
# `paths:` key is refused -- as is a quoted `paths` key, which this
# line-level reader refuses rather than decodes, because a filter it cannot
# decode cannot be told from an allow-list. Spacing a key leaves before its
# colon (`paths :`, `"paths" :`) is matched too -- YAML honours it -- and
# the push arm's verdict reads the canonical key (`paths` / `paths-ignore`),
# quoting and spacing normalised away.
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
    for trigger in ("pull_request:", "pull_request_target:", "push:"):
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
        if trigger == "push:":
            # Opposite polarity from the arms above, and the verdict reads
            # the key as the whole decoded token rather than a substring, so
            # a comment or a value's prose can neither satisfy nor evade it.
            # A quoted `paths` key -- a line this reader cannot classify --
            # is refused rather than passed.
            filters = set()
            for line in body[starts[0]:stop]:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                match = re.match(r"(paths(-ignore)?)\s*:", stripped)
                if match:
                    filters.add(match.group(1))
                elif re.match(r"['\"]paths(-ignore)?['\"]\s*:", stripped):
                    fail(f"{workflow.name}'s push: trigger spells its path "
                         f"filter as a quoted key, which this line-level "
                         f"check refuses rather than parses; spell it "
                         f"`paths:` or `paths-ignore:`")
            if "paths" in filters:
                fail(f"{workflow.name}'s push: trigger must not carry a "
                     f"`paths:` allow-list: it stops the gate running on "
                     f"main after any unrelated change, and no pull request "
                     f"ever blocks to say so; deny-list with `paths-ignore:` "
                     f"instead")
        elif any(re.match(r"\s*paths(-ignore)?\s*:", line)
                 or re.match(r"\s*['\"]paths(-ignore)?['\"]\s*:", line)
                 for line in body[starts[0]:stop]):
            fail(f"{workflow.name}'s {trigger} trigger must carry no paths "
                 f"filter: a workflow with a required job that does not run "
                 f"reports no status, and the pull request blocks forever")

if "  pull_request:" not in lines:
    fail("tests.yml must keep its unfiltered `pull_request:` trigger")
PYWIRE
}

# The commit-scope check's own wiring pin. Placement is pinned with the body --
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

prefixed_environment_only() {
  python3 - "$ROOT" <<'PYENV'
from pathlib import Path
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("claim", Path(sys.argv[1]) / "claim.py")
claim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claim)
os.environ.clear()
for name in ("BODY", "ACTOR_TYPE", "ISSUE", "REPOSITORY", "ACTOR", "MAX_CLAIMS", "EXPIRE"):
    for value in (f"prefixed-{name}", ""):
        os.environ[f"CLAIM_{name}"] = value
        assert claim.input_env(name) == value, f"{name}: prefixed value was not used"
PYENV
}

legacy_environment_only() {
  python3 - "$ROOT" <<'PYENV'
from pathlib import Path
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("claim", Path(sys.argv[1]) / "claim.py")
claim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claim)
os.environ.clear()
for name in ("BODY", "ACTOR_TYPE", "ISSUE", "REPOSITORY", "ACTOR", "MAX_CLAIMS", "EXPIRE"):
    try:
        claim.input_env(name)
    except KeyError as error:
        assert error.args == (name,), f"{name}: missing input changed its lookup error"
    else:
        raise AssertionError(f"{name}: missing input did not fail")
    for value in (f"legacy-{name}", ""):
        os.environ[name] = value
        assert claim.input_env(name) == value, f"{name}: legacy fallback was not used"
PYENV
}

prefixed_environment_wins() {
  python3 - "$ROOT" <<'PYENV'
from pathlib import Path
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("claim", Path(sys.argv[1]) / "claim.py")
claim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claim)
os.environ.clear()
for name in ("BODY", "ACTOR_TYPE", "ISSUE", "REPOSITORY", "ACTOR", "MAX_CLAIMS", "EXPIRE"):
    os.environ[name] = f"legacy-{name}"
    for value in (f"prefixed-{name}", ""):
        os.environ[f"CLAIM_{name}"] = value
        assert claim.input_env(name) == value, f"{name}: prefixed value lost to legacy value"
PYENV
}

action_contract() {
  python3 "$ROOT/tests/action_contract.py" "$ROOT"
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

# The Install block and claim.yml are two hand-kept copies of one manifest,
# and the only gate that reads both files — actionlint.yml's "Check the README
# pin matches claim.yml" step — compares the action pins and nothing else.
# Editing either copy alone therefore shipped green — for the job condition
# bfe9aad pinned, for the step's `with:` values, and equally for the job's
# `runs-on`, `timeout-minutes` and `permissions:` block and the whole
# top-level `concurrency:` block (#130), which sits outside `jobs:` and is
# sliced from the same significant-lines list the job locator reads. This
# case reads all of that out of BOTH files, each through its own parse of
# its own text, with a reader that models only the shapes these two files
# use — a block-scalar body (whose `#`-initial lines are content there and
# refuse rather than strip), an on-key-line plain or quoted scalar (whose
# deeper-indented continuation lines refuse rather than join), and the
# wrapper forms around those — and refuses every shape outside that set, so
# a value it cannot read is a red refusal and never a guessed one. The two
# conditions are compared with whitespace folded: the folded `>-` scalar's
# line breaks and the more-indented `||` continuation lines compare equal,
# so only a difference in the condition's tokens reddens. The `with:` values
# are compared as their DECODED scalars — quote-stripped, so a comment or a
# spelling difference cannot satisfy the compare — exactly, with no folding:
# `max-claims` and `expire` are single-line quoted literals in both files,
# and the value itself is the contract. The `permissions:` and
# `concurrency:` blocks compare as exact key sets over only the keys this
# check models — `issues` and `pull-requests`; `group`, `cancel-in-progress`,
# `queue` — and a key outside that set refuses on either surface, never a
# text-compare of a key only one copy carries. The concurrency `group` keeps
# its embedded
# `${{ github.event.issue.number }}` IN the compare — the one deliberate
# exception to the readers' expression refusal: both copies must spell the
# group identically, and a one-sided edit to the expression is precisely
# the drift this check exists to redden.
readme_install_block_matches_claim_yml() {
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


def significant_lines_of(path, text):
    """a manifest's significant lines as (indent, text, is_comment) — the
    one list every locator below slices, so no second parser exists."""
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
        # the block readers below may decide what one means.
        significant.append((len(lead), stripped, stripped.startswith("#")))
    return significant


def job_block_of(path, significant):
    """the claim job's lines sliced from one manifest's significant lines,
    refusing every shape outside the set modelled below."""

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
    return jobs_block[start:stop]


def condition_of(path, job_block):
    """jobs.claim.if read out of the claim job's lines, refusing every shape
    outside the set modelled below."""
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


def with_of(path, job_block):
    """the action step's `with:` mapping read as decoded values, refusing
    every shape outside the set modelled below."""
    inline = [s for indent, s, comment in job_block
              if indent == 4 and not comment
              and s.startswith("steps:") and s != "steps:"]
    assert not inline, (
        f"{path}: `steps:` carries an inline value this reader does not model: "
        f"{inline[0]!r}")
    steps_at = [i for i, (indent, s, comment) in enumerate(job_block)
                if indent == 4 and not comment and s == "steps:"]
    assert len(steps_at) == 1, (
        f"{path}: expected exactly one `steps:` at indent 4 in the claim job, "
        f"found {len(steps_at)}")
    start = steps_at[0] + 1
    stop = next((i for i in range(start, len(job_block))
                 if job_block[i][0] <= 4 and not job_block[i][2]),
                len(job_block))
    steps_block = job_block[start:stop]
    items = [(i, s) for i, (indent, s, comment) in enumerate(steps_block)
             if not comment and s.startswith("- ")]
    assert len(items) == 1, (
        f"{path}: expected exactly one step item under `steps:`, "
        f"found {len(items)}")
    item_at, item = items[0]
    assert steps_block[item_at][0] == 6, (
        f"{path}: the step item does not sit at indent 6 under `steps:`")
    assert item.startswith("- uses:"), (
        f"{path}: the step item does not open with `uses:`; a step this "
        f"reader does not model: {item!r}")
    inline = [s for indent, s, comment in steps_block[item_at + 1:]
              if 6 < indent and not comment
              and s.startswith("with:") and s != "with:"]
    assert not inline, (
        f"{path}: `with:` carries an inline value this reader does not model: "
        f"{inline[0]!r}")
    withs_at = [i for i, (indent, s, comment) in
                enumerate(steps_block[item_at + 1:], item_at + 1)
                if 6 < indent and not comment and s == "with:"]
    assert len(withs_at) == 1, (
        f"{path}: expected exactly one `with:` in the action's step, "
        f"found {len(withs_at)}")
    start = withs_at[0] + 1
    stop = next((i for i in range(start, len(steps_block))
                 if steps_block[i][0] <= 8 and not steps_block[i][2]),
                len(steps_block))
    with_block = steps_block[start:stop]
    values = {}
    for indent, s, comment in with_block:
        if comment:
            continue
        key, sep, rest = s.partition(":")
        assert key in ("max-claims", "expire") and sep, (
            f"{path}: a `with:` key this check does not compare is a shape "
            f"this reader does not model: {s!r}")
        assert key not in values, (
            f"{path}: duplicate `with:` key {key!r}")
        rest = rest.strip()
        assert rest, (
            f"{path}: `{key}:` carries no value on its key line; a value on a "
            f"following line is a shape this reader does not model")
        if rest[0] in ("'", '"'):
            value = quoted_scalar(path, rest)
        else:
            assert " #" not in rest, (
                f"{path}: trailing comment in a plain scalar, which this "
                f"reader does not model: {rest!r}")
            assert rest[0] not in "&*!?%@`{[|>", (
                f"{path}: a value opening with the indicator {rest[0]!r} is a "
                f"shape this reader does not model: {rest!r}")
            value = rest
        assert "${{" not in value and "}}" not in value, (
            f"{path}: an embedded expression in `{key}:` is a shape this "
            f"reader does not model: {rest!r}")
        values[key] = value
    assert set(values) == {"max-claims", "expire"}, (
        f"{path}: expected exactly the `with:` keys max-claims and expire, "
        f"found {sorted(values)}")
    return values


def job_scalar_of(path, job_block, key):
    """jobs.claim.<key> read as a decoded on-key-line scalar, refusing every
    shape outside the set modelled below."""
    keys_at = [i for i, (indent, s, comment) in enumerate(job_block)
               if indent == 4 and not comment and s.startswith(f"{key}:")]
    assert len(keys_at) == 1, (
        f"{path}: expected exactly one job-level `{key}:` at indent 4 in the "
        f"claim job, found {len(keys_at)}")
    rest = job_block[keys_at[0]][1][len(key) + 1:].strip()
    assert rest, (
        f"{path}: `{key}:` carries no value on its key line; a value on a "
        f"following line is a shape this reader does not model")
    if rest[0] in ("'", '"'):
        value = quoted_scalar(path, rest)
    else:
        assert " #" not in rest, (
            f"{path}: trailing comment in a plain scalar, which this reader "
            f"does not model: {rest!r}")
        assert rest[0] not in "&*!?%@`{[|>", (
            f"{path}: a value opening with the indicator {rest[0]!r} is a "
            f"shape this reader does not model: {rest!r}")
        value = rest
    assert "${{" not in value and "}}" not in value, (
        f"{path}: an embedded expression in `{key}:` is a shape this reader "
        f"does not model: {rest!r}")
    # Per YAML a deeper-indented line after an on-key-line scalar CONTINUES
    # it, so an extra conjunct indented past the key would silently join a
    # value this reader never reads. It is refused, never skipped.
    followers = [(indent, s) for indent, s, comment
                 in job_block[keys_at[0] + 1:] if not comment]
    if followers and followers[0][0] > 4:
        refuse(path, f"a continuation line after an on-key-line `{key}:` "
                     f"value is a shape this reader does not model: "
                     f"{followers[0][1]!r}")
    return value


def permissions_of(path, job_block):
    """jobs.claim.permissions read out of the claim job's lines, refusing
    every shape outside the set modelled below."""
    inline = [s for indent, s, comment in job_block
              if indent == 4 and not comment
              and s.startswith("permissions:") and s != "permissions:"]
    assert not inline, (
        f"{path}: `permissions:` carries an inline value this reader does "
        f"not model: {inline[0]!r}")
    perms_at = [i for i, (indent, s, comment) in enumerate(job_block)
                if indent == 4 and not comment and s == "permissions:"]
    assert len(perms_at) == 1, (
        f"{path}: expected exactly one `permissions:` at indent 4 in the "
        f"claim job, found {len(perms_at)}")
    start = perms_at[0] + 1
    stop = next((i for i in range(start, len(job_block))
                 if job_block[i][0] <= 4 and not job_block[i][2]),
                len(job_block))
    perms_block = job_block[start:stop]
    values = {}
    for indent, s, comment in perms_block:
        if comment:
            continue
        assert indent == 6, (
            f"{path}: a line at indent {indent} inside the `permissions:` "
            f"block is a shape this reader does not model: {s!r}")
        key, sep, rest = s.partition(":")
        assert key in ("issues", "pull-requests") and sep, (
            f"{path}: a `permissions:` key this check does not compare is a "
            f"shape this reader does not model: {s!r}")
        assert key not in values, (
            f"{path}: duplicate `permissions:` key {key!r}")
        rest = rest.strip()
        assert rest, (
            f"{path}: `{key}:` carries no value on its key line; a value "
            f"on a following line is a shape this reader does not model")
        if rest[0] in ("'", '"'):
            value = quoted_scalar(path, rest)
        else:
            assert " #" not in rest, (
                f"{path}: trailing comment in a plain scalar, which this "
                f"reader does not model: {rest!r}")
            assert rest[0] not in "&*!?%@`{[|>", (
                f"{path}: a value opening with the indicator {rest[0]!r} is "
                f"a shape this reader does not model: {rest!r}")
            value = rest
        assert "${{" not in value and "}}" not in value, (
            f"{path}: an embedded expression in `{key}:` is a shape this "
            f"reader does not model: {rest!r}")
        values[key] = value
    assert set(values) == {"issues", "pull-requests"}, (
        f"{path}: expected exactly the `permissions:` keys issues and "
        f"pull-requests, found {sorted(values)}")
    return values


def concurrency_of(path, significant):
    """the top-level `concurrency:` mapping sliced from one manifest's
    significant lines, refusing every shape outside the set modelled below.
    Its `group` value embeds `${{ … }}` in both files and is compared with
    the expression included: the two surfaces must keep the same spelling,
    and any one-sided edit to it changes the text."""
    inline = [s for indent, s, comment in significant
              if indent == 0 and not comment
              and s.startswith("concurrency:") and s != "concurrency:"]
    assert not inline, (
        f"{path}: `concurrency:` carries an inline value this reader does "
        f"not model: {inline[0]!r}")
    concurs_at = [i for i, (indent, s, comment) in enumerate(significant)
                  if indent == 0 and not comment and s == "concurrency:"]
    assert len(concurs_at) == 1, (
        f"{path}: expected exactly one top-level `concurrency:` block "
        f"mapping, found {len(concurs_at)}")
    start = concurs_at[0] + 1
    stop = next((i for i in range(start, len(significant))
                 if significant[i][0] == 0 and not significant[i][2]),
                len(significant))
    concurs_block = significant[start:stop]
    values = {}
    for indent, s, comment in concurs_block:
        if comment:
            continue
        assert indent == 2, (
            f"{path}: a line at indent {indent} inside the `concurrency:` "
            f"block is a shape this reader does not model: {s!r}")
        key, sep, rest = s.partition(":")
        assert key in ("group", "cancel-in-progress", "queue") and sep, (
            f"{path}: a `concurrency:` key this check does not compare is a "
            f"shape this reader does not model: {s!r}")
        assert key not in values, (
            f"{path}: duplicate `concurrency:` key {key!r}")
        rest = rest.strip()
        assert rest, (
            f"{path}: `{key}:` carries no value on its key line; a value on "
            f"a following line is a shape this reader does not model")
        if rest[0] in ("'", '"'):
            value = quoted_scalar(path, rest)
        else:
            assert " #" not in rest, (
                f"{path}: trailing comment in a plain scalar, which this "
                f"reader does not model: {rest!r}")
            assert rest[0] not in "&*!?%@`{[|>", (
                f"{path}: a value opening with the indicator {rest[0]!r} is "
                f"a shape this reader does not model: {rest!r}")
            value = rest
        # No embedded-expression refusal here, the readers' one deliberate
        # exception (#130): `group` embeds `${{ github.event.issue.number }}`
        # in both files, the two copies must keep the same spelling of it,
        # and a one-sided edit changes the decoded text — so the expression
        # compares like any other part of the value.
        values[key] = value
    assert set(values) == {"group", "cancel-in-progress", "queue"}, (
        f"{path}: expected exactly the `concurrency:` keys group, "
        f"cancel-in-progress and queue, found {sorted(values)}")
    return values


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


readme_lines = significant_lines_of("README.md install block", installs[0])
workflow_lines = significant_lines_of(".github/workflows/claim.yml", workflow)
readme_job = job_block_of("README.md install block", readme_lines)
workflow_job = job_block_of(".github/workflows/claim.yml", workflow_lines)

readme_condition = fold(condition_of("README.md install block", readme_job))
workflow_condition = fold(condition_of(".github/workflows/claim.yml", workflow_job))
assert readme_condition == workflow_condition, (
    "the README install block's job condition drifted from claim.yml's:"
    f"\n  README.md: {readme_condition!r}"
    f"\n  claim.yml: {workflow_condition!r}")

readme_with = with_of("README.md install block", readme_job)
workflow_with = with_of(".github/workflows/claim.yml", workflow_job)
assert readme_with == workflow_with, (
    "the README install block's `with:` values drifted from claim.yml's:"
    f"\n  README.md: {readme_with!r}"
    f"\n  claim.yml: {workflow_with!r}")

readme_scalars = {key: job_scalar_of("README.md install block", readme_job, key)
                  for key in ("runs-on", "timeout-minutes")}
workflow_scalars = {
    key: job_scalar_of(".github/workflows/claim.yml", workflow_job, key)
    for key in ("runs-on", "timeout-minutes")}
assert readme_scalars == workflow_scalars, (
    "the README install block's job `runs-on`/`timeout-minutes` values "
    "drifted from claim.yml's:"
    f"\n  README.md: {readme_scalars!r}"
    f"\n  claim.yml: {workflow_scalars!r}")

readme_permissions = permissions_of("README.md install block", readme_job)
workflow_permissions = permissions_of(".github/workflows/claim.yml", workflow_job)
assert readme_permissions == workflow_permissions, (
    "the README install block's `permissions:` block drifted from claim.yml's:"
    f"\n  README.md: {readme_permissions!r}"
    f"\n  claim.yml: {workflow_permissions!r}")

readme_concurrency = concurrency_of("README.md install block", readme_lines)
workflow_concurrency = concurrency_of(".github/workflows/claim.yml", workflow_lines)
assert readme_concurrency == workflow_concurrency, (
    "the README install block's `concurrency:` block drifted from claim.yml's:"
    f"\n  README.md: {readme_concurrency!r}"
    f"\n  claim.yml: {workflow_concurrency!r}")
PY
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
  env -i PATH="$empty" GH_TOKEN=test-token CLAIM_REPOSITORY=owner/project CLAIM_ISSUE=7 \
    CLAIM_ACTOR=octo-claimant CLAIM_ACTOR_TYPE=User CLAIM_BODY=/claim \
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

# The CodeQL matrix pin lives in tests/codeql_matrix.py: a guard that reads
# only the lines it depends on and refuses rather than parses. Issue #87
# deleted the block-layout YAML reader that used to walk the whole workflow
# here -- a second YAML implementation, one refusal arm per review round.
# The case below runs it green over the tree as it ships.
codeql_matrix_covers_python() {
  python3 "$ROOT/tests/codeql_matrix.py" "$ROOT"
}

# --- the patch-coverage reporter (issue #129's script), issue #137 ----------
#
# The script decides with a hunk walk, a git-quoted path decoder, a
# statement-record check and a handful of render cases; every branch is
# pinned here against a COMMITTED fixture pair under tests/diffcoverage/,
# the script run the way the diff-coverage job runs it: from the repository
# root, where .coveragerc sits and claim.py is the source its statement
# analyzer opens. One case per branch, so a broken branch reds exactly its
# own case, and the expectations are hand-written constants the fixtures
# render — never values read back out of the script.

# The reporter imports coverage at module level, so a python3 without it
# cannot even start the script. The ubuntu cell installs the pinned coverage
# before the suite runs, so the controls run there every time; a python3
# without the module says so and passes, loudly, rather than red-ing a cell
# that never promised the dependency.
diffcoverage_skip_unless_coverage() {
  if python3 -c 'import coverage' 2> /dev/null; then
    return 0
  fi
  printf '  SKIP diff-coverage controls: coverage is not importable from python3 here\n'
  return 2
}

# From the repository root: the statement analyzer reads .coveragerc and
# claim.py relative to the working directory.
run_diffcoverage() {
  local status=0
  (cd "$ROOT" && python3 .github/scripts/diff_coverage.py \
    --coverage "tests/diffcoverage/$1" \
    --diff "tests/diffcoverage/$2" \
    > "$GH_CASE/out" 2> "$GH_CASE/err") || status=$?
  return "$status"
}

diffcoverage_renders() {
  local xml=$1 diff=$2 status=0 failed=0
  run_diffcoverage "$xml" "$diff" || status=$?
  if [[ $status -ne 0 ]]; then
    printf '  exit status: expected 0, got %s\n' "$status"
    failed=1
  fi
  if [[ ! -f $GH_CASE/expected ]]; then
    printf '  the case wrote no expected body\n'
    return 1
  fi
  diff -u "$GH_CASE/expected" "$GH_CASE/out" || failed=1
  if grep -Fq Traceback "$GH_CASE/err"; then
    printf '  unexpected traceback\n'
    failed=1
  fi
  return "$failed"
}

diffcoverage_refuses_with() {
  # The refusal shape every invalid input owes: exit 1, nothing on stdout,
  # no traceback, and a first stderr line starting with the caller's text.
  # The absent-records case passes only a prefix: the ranges after it are
  # read off claim.py's current shape, so pinning them would red the suite
  # on every honest edit of the file.
  local prefix=$1 xml=$2 diff=$3 status=0 failed=0
  run_diffcoverage "$xml" "$diff" || status=$?
  if [[ $status -ne 1 ]]; then
    printf '  exit status: expected 1, got %s\n' "$status"
    failed=1
  fi
  if [[ -s $GH_CASE/out ]]; then
    printf '  the refusal wrote to stdout\n'
    failed=1
  fi
  if ! [[ $(sed -n '1p' "$GH_CASE/err") == "$prefix"* ]]; then
    printf '  the refusal did not start with the expected line:\n'
    sed -n '1p' "$GH_CASE/err"
    failed=1
  fi
  if grep -Fq Traceback "$GH_CASE/err"; then
    printf '  unexpected traceback\n'
    failed=1
  fi
  return "$failed"
}

diffcoverage_hunk_walk_missed_ranges() {
  # The hunk walk turns the diff into added line numbers, and the guard it
  # leans on: a REMOVED line whose content begins `-- ` renders as `--- `
  # and must not be taken for a file header, or the path is cleared mid-hunk
  # and every later hunk of the file drops out of the report in silence. The
  # same fixture pins the missed-ranges table: adjacent misses collapse into
  # a `21-22` span and disjoint ones join with `, `.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

**40.0%** of added lines covered (2/5).

| File | Covered | Added | Missed lines |
| --- | ---: | ---: | --- |
| `claim.py` | 2 | 5 | 21-22, 24 |
EOF
  diffcoverage_renders table.xml table.diff
}

diffcoverage_quoted_path_decode() {
  # A git-quoted path arrives with quotes and `\NNN` octal escapes; the
  # decoder must strip both and land on the name the report uses. The
  # fixture's quoted spelling decodes to claim.py, so a decoder that keeps
  # the quoting renders "no measured lines" instead of this table.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

**100.0%** of added lines covered (2/2).

| File | Covered | Added | Missed lines |
| --- | ---: | ---: | --- |
| `claim.py` | 2 | 2 | — |

Every added line was reached.
EOF
  diffcoverage_renders quoted.xml quoted.diff
}

diffcoverage_quoted_path_invalid_utf8() {
  # The quoted-path decode happens INSIDE the report guard, so an escape
  # sequence whose bytes are not UTF-8 is a one-line refusal naming the
  # report, not a traceback.
  diffcoverage_skip_unless_coverage || return 0
  diffcoverage_refuses_with \
    "coverage report invalid: 'utf-8' codec can't decode byte 0xff in position 4: invalid start byte" \
    minimal.xml quoted-invalid.diff
}

diffcoverage_whole_diff_unreadable_bytes() {
  # The whole-diff decode is replacement, never refusal: the diff is
  # git-generated and the workflow diffs with --text, so a tracked file's
  # bytes are rendered here verbatim and one unreadable line in an
  # unrelated file must not fail a legitimate tree's report. The fixture
  # carries raw non-UTF-8 bytes in a NON-measured file's added line beside
  # a clean claim.py hunk; the report must be byte-for-byte the clean
  # control's body, with the measured row unchanged and correct.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

**100.0%** of added lines covered (1/1).

| File | Covered | Added | Missed lines |
| --- | ---: | ---: | --- |
| `claim.py` | 1 | 1 | — |

Every added line was reached.
EOF
  diffcoverage_renders quoted.xml wholediff-utf8.diff
}

diffcoverage_binary_diff_refused() {
  # A binary diff record carries no line numbers to measure, so it is a
  # refusal, never an empty report read as a clean one.
  diffcoverage_skip_unless_coverage || return 0
  diffcoverage_refuses_with \
    'coverage report invalid: binary diff record is not measurable: Binary files a/claim.py and b/claim.py differ' \
    minimal.xml binary.diff
}

diffcoverage_absent_statement_records() {
  # The hard error: an added executable statement with no XML record must
  # refuse rather than shrink the denominator. The fixture claims lines
  # 30-40 of claim.py, which hold real statements, and records none of them;
  # the refusal's ranges are claim.py's to move, so only the prefix is
  # pinned.
  diffcoverage_skip_unless_coverage || return 0
  diffcoverage_refuses_with \
    'coverage report invalid: missing executable statement records for claim.py: ' \
    absent.xml absent.diff
}

diffcoverage_duplicate_class_max_hits() {
  # A file can appear as more than one <class>; a line reached by any of
  # them counts as covered, which is the max() over the duplicate records —
  # last-wins or min() here renders line 1 missed and this body changes.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

**100.0%** of added lines covered (1/1).

| File | Covered | Added | Missed lines |
| --- | ---: | ---: | --- |
| `claim.py` | 1 | 1 | — |

Every added line was reached.
EOF
  diffcoverage_renders merge.xml merge.diff
}

diffcoverage_no_measured_lines() {
  # A change confined to files the report does not measure is said in full,
  # because a bare "nothing added" reads like the tool failed to find the
  # diff.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

No **measured** lines were added. The report measures only `claim.py` (`[report] include` in `.coveragerc`), so a change confined to the suite, the workflows or any other file has no patch coverage to report -- that is not the same as none of it running.
EOF
  diffcoverage_renders minimal.xml nomeasured.diff
}

diffcoverage_unmeasured_changed_source() {
  # A changed source path the report never named is listed, because a
  # systematic spelling mismatch is otherwise indistinguishable from a
  # change confined to unmeasured files.
  diffcoverage_skip_unless_coverage || return 0
  cat > "$GH_CASE/expected" <<'EOF'
### Coverage of this change

This change added lines to claim.py, the one file the coverage report measures, but the report names none of the changed paths. Nothing here was measured, which is not the same as nothing needing to be: the report most likely spells paths differently than the diff does.

Unmeasured changed source files:
- `claim.py`
EOF
  diffcoverage_renders minimal.xml unmeasured.diff
}

diffcoverage_artifact_names_one_leg() {
  # A run's artifact names are one namespace shared by every job in it, so
  # the wiring must keep exactly one uploader per name. A second leg under
  # the same name would leave the download resolving the pair however it likes.
  python3 - "$ROOT/.github/workflows/tests.yml" <<'PYWIRE'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
found = []
for block in re.split(r"\n(?=      - )", text):
    if not re.search(r"^        uses: actions/upload-artifact@", block, re.M):
        continue
    names = re.findall(r"^          name: (\S+)", block, re.M)
    if len(names) != 1:
        print(f"tests.yml's uploading block carries {len(names)} name lines, "
              "expected exactly one: an uploading leg without exactly one "
              "name leaves the run's artifact namespace ambiguous",
              file=sys.stderr)
        raise SystemExit(1)
    found.extend(names)
duplicates = sorted({name for name in found if found.count(name) > 1})
if duplicates:
    print(f"tests.yml's upload-artifact steps duplicate names {duplicates!r}: "
          "one artifact namespace per run means exactly one uploading leg "
          "per name: a download would resolve the pair however it likes",
          file=sys.stderr)
    raise SystemExit(1)
PYWIRE
}

# Issue 141: the suite-legs pin lives in tests/suite_legs.py, in the
# codeql_matrix shape -- a guard that reads the tests.yml matrix and every
# step's `if:`, the README coverage table, and fails naming the row and the
# legs when the two drift apart. The case below runs it green over the tree
# as it ships.
suite_legs_covers_readme() {
  python3 "$ROOT/tests/suite_legs.py" "$ROOT"
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
  prefixed_environment_only legacy_environment_only prefixed_environment_wins
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
  # Issue 198: deletion ends successfully with no retry, reply or assignment.
  deleted_issue
  # Issue 198: a neighbouring marked 4xx must still fail the run.
  missing_issue_still_fails
  # Issue 198: an unrelated 410 proves no deletion and must fail without writes.
  unrelated_gone_still_fails
  # Issue 198: deletion after a successful issue read still stops without writes.
  deleted_issue_after_read
  # Issue 198: deletion also ends an unclaim command successfully without writes.
  deleted_issue_unclaim
  # Issue 198: deletion also ends a release command successfully without writes.
  deleted_issue_release
  # Issue 159: a transient GitHub failure is retried a bounded number of
  # times before the run fails. One case per branch: the identity lookup and
  # the issue read each get a retried-then-succeeds row and an exhausted
  # row, the unmarked transport shape and a 429 are pinned retryable, a
  # warning beside a healthy answer still reaches the log now that stderr
  # is captured in order to be classified, and the 5xx and transport arms
  # are pinned on two spellings each (a 503 and a 500; a Post and a Get).
  identity_503_retried_then_succeeds identity_503_exhausts_attempts
  snapshot_503_retried snapshot_503_exhausts
  transport_error_retried rate_limit_429_retried
  status_500_retried transport_get_error_retried
  snapshot_warning_on_success_reaches_the_log
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
  # install block's job condition, `with:` values, `runs-on`,
  # `timeout-minutes`, `permissions:` block and top-level `concurrency:`
  # block (held against claim.yml — actionlint.yml's pin step compares the
  # pins alone, so no other gate sees these pairs drift).
action_contract readme_quoted_replies
  readme_install_block_matches_claim_yml codeql_matrix_covers_python
  # Issue 141: the suite-legs pin -- tests.yml leg scoping held against the
  # README coverage table.
  suite_legs_covers_readme
  ratchet_above_hysteresis_keeps_calibration_gap ratchet_equal_writes_nothing
  ratchet_lower_never_loosens ratchet_within_hysteresis_writes_nothing
  ratchet_below_hysteresis_boundary_writes_nothing
  ratchet_exact_hysteresis_boundary_writes_nothing ratchet_raise_uses_decimal_values
  ratchet_recorded_floor_wins
  ratchet_refuses_malformed_json
  ratchet_refuses_non_numeric_measurement ratchet_refuses_non_finite_measurement
  ratchet_refuses_schema ratchet_refuses_missing_or_boolean_schema ratchet_refuses_cell
  ratchet_refuses_missing_fields ratchet_refuses_invalid_record_numbers
  ratchet_push_excludes_fetched_code
  # Issue 64: a green head must carry what main holds, or it vouches for nothing.
  gate_freshness_step_is_wired
  # Issue 90: a workflow's name is a scope only with the ci type.
  commit_scope_step_is_wired
  # Issue #137: the patch-coverage reporter's decision branches, each pinned
  # against a committed fixture pair under tests/diffcoverage/ — one case per
  # branch, hand-written expected bodies, and a loud skip where the coverage
  # module is absent (the ubuntu cell installs it before the suite, so the
  # controls run there every time).
  diffcoverage_hunk_walk_missed_ranges diffcoverage_quoted_path_decode
  diffcoverage_quoted_path_invalid_utf8 diffcoverage_whole_diff_unreadable_bytes
  diffcoverage_binary_diff_refused diffcoverage_absent_statement_records
  diffcoverage_duplicate_class_max_hits diffcoverage_no_measured_lines
  diffcoverage_unmeasured_changed_source diffcoverage_artifact_names_one_leg)
failures=0
for case_name in "${cases[@]}"; do
  GH_CASE="$RUN/$case_name"
  mkdir "$GH_CASE"
  : > "$GH_CASE/expected.jsonl"
  : > "$GH_CASE/calls.jsonl"
  printf '0\n' > "$GH_CASE/sequence"
  printf '0\n' > "$GH_CASE/identity-sequence"
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
