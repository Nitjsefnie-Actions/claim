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


def snapshot(endpoint):
    data = json.loads(gh(endpoint))
    if not isinstance(data, dict) or not isinstance(data.get("state"), str):
        raise ValueError("issue snapshot must contain a state string")
    if not isinstance(data.get("assignees"), list):
        raise ValueError("issue snapshot must contain an assignees array")
    for assignee in data["assignees"]:
        if not isinstance(assignee, dict) or not isinstance(assignee.get("login"), str):
            raise ValueError("issue snapshot assignees must be objects with string logins")
    return data


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
        say(f"Not a command: `{first}`. Comment one of `/claim`, `/unclaim` "
            "or `/release` on its own, optionally followed by the issue "
            f"number, for example `/claim {issue}` or `/claim #{issue}`.")
        return 1
    if match.group(2) is not None and int(match.group(2)) != int(issue):
        say(f"`{command}` names issue {match.group(2)}, but this comment is on "
            f"issue {issue}. Comment `{match.group(1)}` (or "
            f"`{match.group(1)} {issue}`) to act on this issue.")
        return 1
    command = match.group(1)

    initial = snapshot(endpoint)
    # A PR's assignees mean something else, and a closed issue cannot be worked.
    if initial.get("pull_request") is not None:
        say(f"This is a pull request, so `{command}` has no effect here.")
        return 1
    if initial["state"] != "open":
        say(f"This issue is not open, so `{command}` cannot act on it.")
        return 1
    assignees = [assignee["login"] for assignee in initial["assignees"]]

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
            current = ", ".join("@" + login for login in assignees)
            say(f"This issue is already claimed by {current}. "
                "Comment `/unclaim` (or `/release`) if you are giving it up.")
        return 0

    gh("-X", "POST", f"{endpoint}/assignees",
       "-f", f"assignees[]={actor}", "--silent")
    # GitHub can silently ignore an assignee. A failed re-read must abort,
    # never publish a rejection or success based on an unreadable response.
    confirmed = snapshot(endpoint)
    if any(assignee["login"] == actor for assignee in confirmed["assignees"]):
        say(f"Assigned to @{actor}.")
        return 0
    say(f"GitHub would not accept @{actor} as an assignee here. "
        "That usually means the account needs to have commented on or been "
        "granted access to this repository.")
    return 1


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
