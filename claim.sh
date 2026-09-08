#!/usr/bin/env bash
set -euo pipefail

# Exact match on the trimmed body, so "please /claim this when you can" is a
# sentence rather than a command. Strip CR first for Windows clients. Trim the
# whole body, including surrounding blank lines, without altering interior text.
command="${BODY//$'\r'/}"
command="${command#"${command%%[![:space:]]*}"}"
command="${command%"${command##*[![:space:]]}"}"
case "$command" in
  /claim|/unclaim|/release) ;;
  *) printf 'not a command: %s\n' "${command%%$'\n'*}"; exit 0 ;;
esac

say() {
  gh api "repos/$REPO/issues/$ISSUE/comments" -f body="$1" --silent
}

snapshot="$(gh api "repos/$REPO/issues/$ISSUE")"
# A pull request is an issue to this event, but its assignees mean something
# else. A closed issue cannot be worked; a bot's comment is never a claim. The
# caller's prefilter only saves starting a runner: these checks stand on their own.
if [[ $ACTOR_TYPE == Bot ]] || jq -e '.state != "open" or .pull_request != null' <<< "$snapshot" > /dev/null; then
  exit 0
fi

# The reference implementation calls it /release; accept the word people arrive
# expecting as an alias for /unclaim. Both give up only the commenter's claim.
if [[ $command == /unclaim || $command == /release ]]; then
  if ! jq -e --arg actor "$ACTOR" 'any(.assignees[]; .login == $actor)' <<< "$snapshot" > /dev/null; then
    say "@$ACTOR you are not assigned to this issue, so there is nothing to give up."
    exit 0
  fi
  # DELETE names one login, so any other assignee stays.
  gh api -X DELETE "repos/$REPO/issues/$ISSUE/assignees" \
    -f "assignees[]=$ACTOR" --silent
  say "Unassigned @$ACTOR."
  exit 0
fi

if jq -e '.assignees | length > 0' <<< "$snapshot" > /dev/null; then
  if jq -e --arg actor "$ACTOR" 'any(.assignees[]; .login == $actor)' <<< "$snapshot" > /dev/null; then
    say "@$ACTOR you already have this one."
  else
    current="$(jq -r '.assignees[].login' <<< "$snapshot" | sed 's/^/@/' | paste -sd', ' -)"
    say "This issue is already claimed by $current. Comment \`/unclaim\` (or \`/release\`) if you are giving it up."
  fi
  exit 0
fi

gh api -X POST "repos/$REPO/issues/$ISSUE/assignees" \
  -f "assignees[]=$ACTOR" --silent
# GitHub silently ignores an assignee it will not accept, so the assignment is
# confirmed rather than assumed.
confirmed="$(gh api "repos/$REPO/issues/$ISSUE")"
if jq -e --arg actor "$ACTOR" 'any(.assignees[]; .login == $actor)' <<< "$confirmed" > /dev/null; then
  say "Assigned to @$ACTOR."
else
  say "GitHub would not accept @$ACTOR as an assignee here. That usually means the account needs to have commented on or been granted access to this repository."
  exit 1
fi
