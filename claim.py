#!/usr/bin/env python3
"""Handle exact issue-assignment commands, using gh for transport."""

import json
import os
import re
import subprocess
import sys


def gh(*args):
    """Leave authentication, HTTP errors, and rate limits to the CLI."""
    return subprocess.run(
        ["gh", "api", *args], check=True, stdout=subprocess.PIPE, text=True
    ).stdout


def assignee_logins(issue):
    """Return an issue payload's assignee logins, or refuse an unreadable one."""
    if not isinstance(issue, dict) or not isinstance(issue.get("state"), str):
        raise ValueError("issue snapshot must contain a state string")
    if not isinstance(issue.get("assignees"), list):
        raise ValueError("issue snapshot must contain an assignees array")
    for assignee in issue["assignees"]:
        if not isinstance(assignee, dict) or not isinstance(assignee.get("login"), str):
            raise ValueError("issue snapshot assignees must be objects with string logins")
    return [assignee["login"] for assignee in issue["assignees"]]


def snapshot(endpoint):
    return json.loads(gh(endpoint))


def event_actor(event):
    """The login that performed an assignment event, or None if it names none."""
    if not isinstance(event, dict):
        return None
    actor = event.get("actor")
    if not isinstance(actor, dict) or not isinstance(actor.get("login"), str):
        return None
    return actor["login"]


def assignment_timeline(pages):
    """Map every assigned login to the event that assigned it, and to its last one.

    The second map is keyed the same way but survives an unassign, so a run a
    peer's DELETE removed can still recognise the write that was its own.
    """
    current = {}
    last_assigned = {}
    if not isinstance(pages, list):
        raise ValueError("issue events must be an array of pages")
    events = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("issue events must be an array of pages")
        for event in page:
            if not isinstance(event, dict) or not isinstance(event.get("id"), int):
                raise ValueError("issue event must contain an integer id")
            # Every other event type is none of this action's business.
            if event.get("event") not in ("assigned", "unassigned"):
                continue
            assignee = event.get("assignee")
            if not isinstance(assignee, dict) or not isinstance(assignee.get("login"), str):
                raise ValueError("issue event assignee must be an object with a string login")
            events.append((event["id"], event["event"], assignee["login"], event))
    # An assign-and-unassign cycle ends at the LAST event recorded for that
    # login, not the first, which is why the list is replayed into a map
    # instead of being read for the earliest assignment of each login.
    for _, kind, login, event in sorted(events, key=lambda entry: entry[0]):
        if kind == "assigned":
            current[login] = event
            last_assigned[login] = event
        else:
            current.pop(login, None)
    return current, last_assigned


def mention(logins):
    """Format assignee logins the way a comment body names them."""
    return ", ".join("@" + login for login in logins)


def main():
    # Keep shell command recognition: remove CR, then trim only ASCII whitespace.
    command = os.environ["BODY"].replace("\r", "").strip(" \t\n\r\v\f")

    actor_type = os.environ["ACTOR_TYPE"]
    if not actor_type:
        raise ValueError("invalid actor-type: expected a nonempty account type")
    if actor_type != "User":
        print("not a user: " + actor_type.splitlines()[0])
        return 0

    issue = os.environ["ISSUE"]
    repo = os.environ["REPOSITORY"]
    actor = os.environ["ACTOR"]
    if not re.fullmatch(r"[0-9]+", issue):
        raise ValueError("invalid issue: expected digits")
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repo)
            or repo.split("/", 1)[1] in (".", "..")):
        raise ValueError("invalid repository: expected owner/name")

    endpoint = f"repos/{repo}/issues/{issue}"

    def say(body):
        gh(f"{endpoint}/comments", "-f", f"body={body}", "--silent")

    # The number must share the command's line: a body with a newline is
    # prose, not a command followed by a number on the next line.
    match = re.fullmatch(r"(/claim|/unclaim|/release)(?:[ \t\v\f]+#?([0-9]+))?", command)
    # Replies wait for the Bot refusal above: the replies quote the command
    # words, and only that refusal stops a caller that triggers on its own
    # comments from answering itself forever.
    if match is None:
        first = command.split("\n", 1)[0]
        print("not a command: " + first)
        # The line's own backticks are escaped so they cannot end the code
        # span the reply quotes it in.
        quoted = first.replace("`", "\\`")
        say(f"Not a command: `{quoted}`. Comment one of `/claim`, `/unclaim` "
            "or `/release` on its own, optionally followed by the issue "
            f"number, for example `/claim {issue}` or `/claim #{issue}`.")
        return 1
    # Compare the digit strings, never through int(): a comment can carry
    # more digits than int() will convert, and the mismatch reply below is
    # the answer such a comment must still get.
    if match.group(2) is not None and match.group(2).lstrip("0") != issue.lstrip("0"):
        say(f"`{command}` names issue {match.group(2)}, but this comment is on "
            f"issue {issue}. Comment `{match.group(1)}` (or "
            f"`{match.group(1)} {issue}`) to act on this issue.")
        return 1
    command = match.group(1)

    initial = snapshot(endpoint)
    assignees = assignee_logins(initial)
    # A PR's assignees mean something else, and a closed issue cannot be worked.
    if initial.get("pull_request") is not None:
        say(f"This is a pull request, so `{command}` has no effect here.")
        return 1
    if initial["state"] != "open":
        say(f"This issue is not open, so `{command}` cannot act on it.")
        return 1

    if command in ("/unclaim", "/release"):
        if actor not in assignees:
            say(f"@{actor} you are not assigned to this issue, "
                "so there is nothing to give up.")
            return 0
        # DELETE names exactly one login so every other assignee stays.
        gh("-X", "DELETE", f"{endpoint}/assignees",
           "-f", f"assignees[]={actor}", "--silent")
        say(f"Unassigned @{actor}.")
        return 0

    if assignees:
        if actor in assignees:
            say(f"@{actor} you already have this one.")
        else:
            say(f"This issue is already claimed by {mention(assignees)}. "
                "Comment `/unclaim` (or `/release`) if you are giving it up.")
        return 0

    # Assigning is additive: a second claimant is added beside the first rather
    # than refused, so two runs that both read an empty assignee list can both
    # write and leave the issue held twice. The POST's own body is the only
    # place this run can learn whether ITS assignment was accepted — a peer
    # that removes this login before the re-read is then indistinguishable from
    # GitHub declining the assignee, and the run would blame the commenter's
    # account for a race it lost. The POST is reached only when the first
    # snapshot held nobody, so every assignee confirmed below arrived after
    # that read: the removals below reach only recent assignees, and only the
    # ones the issue's events attribute to this action's own writes.
    assigned = assignee_logins(json.loads(
        gh("-X", "POST", f"{endpoint}/assignees", "-f", f"assignees[]={actor}")))
    if actor not in assigned:
        say(f"GitHub would not accept @{actor} as an assignee here. "
            "That usually means the account needs to have commented on or been "
            "granted access to this repository.")
        return 1
    # A failed re-read must abort, never publish a rejection or success based
    # on an unreadable response.
    confirmed = assignee_logins(snapshot(endpoint))
    if confirmed == [actor]:
        say(f"Assigned to @{actor}.")
        return 0
    if not confirmed:
        # Every assignment this run can see has been removed by somebody else,
        # so there is nobody to name and nothing to settle.
        say(f"@{actor} nothing is assigned to this issue any more.")
        return 0
    # The order comes from the issue's events, not from the assignee list,
    # because the list carries no order: {alice, bob} read by two runs that
    # both POSTed, and {bob, alice} read by a run that finished second, are
    # the same list, and any rule over the list alone breaks one of them. The
    # earliest assignment event is the one nothing removes, so the first
    # claimant is permanent; every later claim is removed by a run that read it
    # beside an earlier one, or by its own run, and a run that never reaches
    # its re-read is covered by the next one that does. An assignment this
    # action cannot attribute to its own writes is never removed at all, which
    # is what keeps a maintainer's manual assignment safe.
    current, last_assigned = assignment_timeline(json.loads(
        gh("--paginate", "--slurp", f"{endpoint}/events?per_page=100")))
    # Read off this run's own assignment event, which an unassign has not
    # erased: a run a peer removed still has to recognise its own write.
    token = event_actor(current.get(actor) or last_assigned.get(actor))
    if token is None or any(login not in current for login in confirmed):
        # The order is unreadable — an event not yet visible, a page the read
        # did not follow, or a login assigned before the window. Changing
        # nothing is the only answer that cannot destroy a stranger's write.
        say(f"@{actor} this issue is assigned to more than one person. This "
            "run could not determine who was assigned first, so no assignment "
            "was changed.")
        return 1
    claims = [login for login in confirmed if event_actor(current[login]) == token]
    if len(claims) < len(confirmed):
        # Somebody assigned this issue by hand inside the window. That person
        # holds it: the action yields to a write it cannot attribute to
        # itself rather than delete it, and does not call it a claim, because
        # only the events say who did it and this run cannot read that.
        holders = [login for login in confirmed
                   if login not in claims and login != actor]
        if actor in confirmed:
            gh("-X", "DELETE", f"{endpoint}/assignees",
               "-f", f"assignees[]={actor}", "--silent")
        say(f"@{actor} this issue is assigned to {mention(holders)}, so "
            "nothing was assigned to you.")
        return 0
    winner = min(claims, key=lambda login: current[login]["id"])
    # Every claim later than the winner's, this run's own login included: a
    # run that writes last may be the second of a pair it read, and a pair it
    # read is a pair it must not leave behind.
    removed = [login for login in claims
               if current[login]["id"] > current[winner]["id"]]
    for login in removed:
        # DELETE names exactly one login so every other assignee stays.
        gh("-X", "DELETE", f"{endpoint}/assignees",
           "-f", f"assignees[]={login}", "--silent")
    if winner != actor:
        say(f"@{actor} @{winner} claimed this issue at the same time and "
            "holds it, so your claim was released.")
        return 0
    if removed:
        were = "were" if len(removed) > 1 else "was"
        that = ("those assignments were" if len(removed) > 1
                else "that assignment was")
        say(f"Assigned to @{actor}. {mention(removed)} {were} assigned at the "
            f"same time, so {that} removed.")
        return 0
    say(f"Assigned to @{actor}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except json.JSONDecodeError as error:
        print(f"parse error: {error}", file=sys.stderr)
        sys.exit(1)
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
