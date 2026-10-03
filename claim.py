#!/usr/bin/env python3
"""Handle exact issue-assignment commands, using gh for transport."""

from datetime import datetime, timezone
import json
import os
import re
import subprocess
import sys


# GitHub refuses a comment body over 65,536 characters. Every reply in this
# file passes through say(), which replaces one this long rather than posting
# it: the defect this closes is a reply that quotes an unbounded slice of the
# commenter's body, which makes the reply a thing the commenter sizes, and
# bound at the helper all replies reach it is closed for every reply that
# exists — and for any added later.
MAX_COMMENT = 65536

# An App installation token — which the default `${{ github.token }}` is — is
# refused by `GET /user` with HTTP 403 "Resource not accessible by
# integration" (verified on an Actions runner 2026-10-01), while a user token
# answers 200 with its account. That one verified refusal is what earns the
# None below; nothing here claims GitHub's refusal vocabulary is closed. Every
# other failure is news about the run rather than about the token's shape — a
# rate limit, a network error, a 5xx, a 401, a 403 saying something else — and
# folding those into the same answer would silently switch the caller's
# self-account guard off.
#
# The phrase is matched in gh's MESSAGE LINE, which gh writes to stderr; the
# same text also sits in the JSON error body, which gh writes to stdout
# (measured against gh 2.98.0), so a matcher reading the body would call a
# healthy 200 a refusal.
INSTALLATION_REFUSAL = "Resource not accessible by integration"


def gh(*args, stdin=None):
    """Leave authentication, HTTP errors, and rate limits to the CLI."""
    return subprocess.run(
        ["gh", "api", *args], check=True, input=stdin,
        stdout=subprocess.PIPE, text=True
    ).stdout


def own_identity():
    """The login this token writes as, or None when it has no user account.

    None is earned by exactly one answer: the nonzero exit whose stderr
    carries INSTALLATION_REFUSAL, the documented `/user` refusal of an App
    installation token, which is what the default `${{ github.token }}` is.
    Every other failure raises, because the caller skips the self-account
    guard on a None, and an action that cannot say which account its own
    token writes as must not go on to answer a comment from that account.
    A 200 whose body is unreadable is an error for the same reason: it too
    would compare the commenter against an identity never established.
    """
    probe = subprocess.run(
        ["gh", "api", "user"], check=False, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True,
    )
    if probe.returncode != 0:
        if INSTALLATION_REFUSAL in probe.stderr:
            return None
        # All of gh's own words, not the first line: the run log is where a
        # maintainer reads why this run stopped, and stderr was captured
        # rather than passed through, so nothing else would put the reason
        # anywhere. gh's output runs to more than one line whenever it is
        # advice rather than an error — an unauthenticated `gh api` prints two
        # (measured on gh 2.98.0) — and the second line of that pair is the
        # half that names the fix.
        detail = probe.stderr.strip().splitlines()
        raise ValueError(
            "cannot establish which account this token posts as: the /user "
            "lookup failed for a reason other than the documented "
            "installation-token refusal, and reported: "
            + ("\n".join(detail) if detail
               else f"nothing, exit status {probe.returncode}")
        )
    identity = json.loads(probe.stdout)
    if not isinstance(identity, dict) or not isinstance(identity.get("login"), str):
        raise ValueError("identity snapshot must contain a login string")
    return identity["login"]


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


def open_claims(repo, actor):
    """Count one account's open assigned issues in one repository, via search."""
    result = json.loads(gh("-X", "GET", "search/issues", "-f",
                           f"q=repo:{repo} is:issue is:open assignee:{actor}"))
    # A total that is missing, a string or a bool is a response this run
    # cannot read; proceeding would compare the cap against a number that
    # was never established. Search API and the repository role endpoint
    # both verified live on an Actions runner 2026-10-01 with the default
    # token: total_count carries the full count without pagination,
    # `assignee:` matches case-insensitively, and collaborators/permission
    # answers 200 for an outsider (role_name "read") as well as for the
    # repo owner.
    if not isinstance(result, dict):
        raise ValueError("search snapshot must contain a total_count integer")
    total = result.get("total_count")
    if isinstance(total, bool) or not isinstance(total, int):
        raise ValueError("search snapshot must contain a total_count integer")
    return total


def actor_role(repo, actor):
    """The repository role a login holds here, folded to a cap key."""
    result = json.loads(gh(f"repos/{repo}/collaborators/{actor}/permission"))
    if not isinstance(result, dict):
        raise ValueError("role snapshot must contain a role_name string")
    role = result.get("role_name")
    if not isinstance(role, str):
        raise ValueError("role snapshot must contain a role_name string")
    # The five standard levels pass through under their own names. A
    # custom repository role reports its own name here and the endpoint
    # exposes its base only through the folded `permission` field (triage
    # folds to read, maintain to write), so a custom role counts as its
    # folded base level — documented in the README.
    if role in ("read", "triage", "write", "maintain", "admin"):
        return role
    base = result.get("permission")
    if base not in ("read", "triage", "write", "maintain", "admin"):
        raise ValueError("role snapshot must give a readable role")
    return base


def cap_reply(repo, actor, caps):
    """The cap refusal reply for this actor, or None when under every cap.

    Both /claim paths — fresh and takeover — read their limit here, so the
    two cannot drift: the same role lookup runs, the same search counts, the
    same two refusals leave the issue untouched. A cap of 0 refuses before
    the search call; a finite cap searches first.
    """
    role = actor_role(repo, actor)
    cap = caps.get(role)
    if cap == 0:
        return (f"@{actor} claiming is disabled for your role ({role}) in "
                "this repository. A maintainer can still assign you by hand.")
    if cap is not None and cap > 0:
        total = open_claims(repo, actor)
        if total >= cap:
            claims = "claim" if total == 1 else "claims"
            return (f"@{actor} you already hold {total} open {claims} in "
                    f"this repository, and the cap for your role ({role}) is "
                    f"{cap}. Comment `/unclaim` (or `/release`) on one you "
                    "are giving up, then `/claim` again.")
    return None


def event_actor(event):
    """The login that performed an assignment event, or None if it names none."""
    if not isinstance(event, dict):
        return None
    actor = event.get("actor")
    if not isinstance(actor, dict) or not isinstance(actor.get("login"), str):
        return None
    return actor["login"]


def event_actor_type(event):
    """The account type of an assignment event's actor, or None if untyped."""
    if not isinstance(event, dict):
        return None
    actor = event.get("actor")
    if not isinstance(actor, dict) or not isinstance(actor.get("type"), str):
        return None
    return actor["type"]


def claim_age_days(event):
    """The age in days of an assignment event, or None when unreadable.

    GitHub's created_at is ISO-8601 and may end in Z. A value that is
    missing, not a string, timezone-less or unparseable means the age was
    never established; the caller treats None as NOT expired — an unreadable
    age removes nothing and says so in the run log.
    """
    text = event.get("created_at") if isinstance(event, dict) else None
    if not isinstance(text, str):
        return None
    if text.endswith("Z"):
        # fromisoformat() reads a trailing Z only from Python 3.11, and a
        # runner can be older; "+00:00" parses everywhere.
        text = text[:-1] + "+00:00"
    try:
        created = datetime.fromisoformat(text)
    except ValueError:
        return None
    if created.tzinfo is None:
        return None
    return (datetime.now(timezone.utc) - created).total_seconds() / 86400


def expired_of(current, holders, limit):
    """Split holders into expired (login, whole days) and unreadable-age logins.

    Expiry is STRICTLY older than `limit` days: exactly limit days old is
    not expired. A holder whose age cannot be read is not expired — the age
    was never established, so no claim is removed on it.
    """
    expired = []
    unreadable = []
    for login in sorted(holders):
        age = claim_age_days(current.get(login))
        if age is None:
            unreadable.append(login)
        elif age > limit:
            expired.append((login, int(age)))
    return expired, unreadable


def assignments_are_ours(current, assignees, identity):
    """True when every current assignment is provably a write this token made.

    Every holder needs a readable current `assigned` event, all those events
    must share one actor identity, and that identity must be the token's own:
    the login own_identity() returns, or, for an installation token with no
    user account, its Bot-typed account. Anything less — a holder with no
    readable event, identities that disagree, or one identity that is not
    ours — leaves the writes on the issue unattributable, and only writes the
    action itself made are ever removed. The tie-break and both expiry paths
    share this proof through this helper.
    """
    identities = {(event_actor(current[login]), event_actor_type(current[login]))
                  for login in assignees if login in current}
    if any(login not in current for login in assignees) or len(identities) != 1:
        return False
    ((event_login, event_type),) = identities
    if identity is not None:
        # The None check rides in the return rather than a branch of its
        # own: an actor GitHub could not name leaves None here, and None is
        # no identity to compare against this token's own, so it folds to
        # False — the docstring's answer for an unattributable write —
        # instead of an AttributeError. The account type is not read on
        # this branch; the Bot branch below compares `== "Bot"`, which
        # reads the same on None as on any non-Bot string.
        return (event_login is not None
                and event_login.casefold() == identity.casefold())
    return event_type == "Bot"


def holders_text(expired):
    """The `@login (held N day(s))` list the replies name, in login order."""
    return " and ".join(
        f"@{login} (held {days} day(s))" for login, days in expired)


def holders_log(expired):
    """The same list without mentions, for the run log."""
    return ", ".join(f"{login} (held {days} day(s))" for login, days in expired)


def takeover_reply(expired, actor):
    """The takeover reply: who held how long, and who took over."""
    claim = "claim" if len(expired) == 1 else "claims"
    verb = "has" if len(expired) == 1 else "have"
    return (f"The expired {claim} of {holders_text(expired)} "
            f"{verb} been taken over by @{actor}.")


def release_reply(expired, actor):
    """The privileged-release reply: who acted, who held, how long."""
    return (f"@{actor} has released "
            + " and ".join(f"@{login}'s expired claim (held {days} day(s))"
                           for login, days in expired)
            + ".")


def assignment_timeline(pages, relevant):
    """Map each of `relevant` that is assigned to the event that assigned it.

    Only events naming one of `relevant` are this function's business. The
    issue's history is unbounded — a deleted account's assigned event, or one
    from a claim cycle that ended before this one — and a field this function
    cannot read must leave a login out of the map rather than raise, so the
    caller bails with an explanation instead of the whole issue going dark.
    """
    current = {}
    # GitHub treats logins case-insensitively, so this filter has to as well: an
    # unassigned event spelling an account differently from the issue payload is
    # the same signal, and skipping it would leave a stale assigned behind to
    # win on a stale id and delete a live claim. Keying the map by the
    # spelling the ISSUE payload used keeps every key of `current` a key of
    # `confirmed` by construction, so the lookups the caller makes and the
    # `assignees[]=` DELETE it builds all name the spelling GitHub returned.
    spellings = {login.casefold(): login for login in relevant}
    if not isinstance(pages, list):
        raise ValueError("issue events must be an array of pages")
    events = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("issue events must be an array of pages")
        for event in page:
            if not isinstance(event, dict):
                raise ValueError("issue events must contain event objects")
            # Every other event type is none of this action's business.
            if event.get("event") not in ("assigned", "unassigned"):
                continue
            assignee = event.get("assignee")
            if not isinstance(assignee, dict) or not isinstance(assignee.get("login"), str):
                continue
            login = spellings.get(assignee["login"].casefold())
            if login is None:
                continue
            identifier = event.get("id")
            if isinstance(identifier, bool) or not isinstance(identifier, int):
                continue
            if event_actor(event) is None:
                continue
            events.append((identifier, event["event"], login, event))
    # An assign-and-unassign cycle ends at the LAST event recorded for that
    # login, not the first, which is why the list is replayed into a map
    # instead of being read for the earliest assignment of each login.
    for _, kind, login, event in sorted(events, key=lambda entry: entry[0]):
        if kind == "assigned":
            current[login] = event
        else:
            current.pop(login, None)
    return current


def mention(logins):
    """Format assignee logins the way a comment body names them."""
    return ", ".join("@" + login for login in logins)


def control_escape(text):
    """Escape every C0/C1 control character in text as its \\xNN spelling.

    C0 is U+0000-U+001F and C1 is U+0080-U+009F, and ESC (U+001B) is the
    motivating one: the Actions run log renders ANSI sequences, so a raw
    control character in a declined line recolours or swallows the log's
    own diagnosis instead of being shown, and the reply carries the same
    character into the posted comment. Text with no control character is
    returned unchanged, so a plain decline reads exactly as it always did.
    """
    return re.sub(
        "[\x00-\x1f\x80-\x9f]",
        lambda found: f"\\x{ord(found.group()):02x}",
        text,
    )


def quote_attempt(text):
    """Quote text in a CommonMark code span the text cannot close.

    Backslash escapes do not work inside a code span, so the opening
    delimiter is a backtick run one longer than the longest run in the
    text: a span closes only at a run of exactly equal length, so no
    backtick in the text can end it, and the reply's fixed guidance stays
    outside the span. A text with no backtick is quoted as `text`, the
    shape every existing decline reply pins.
    """
    longest = max(map(len, re.findall(r"`+", text)), default=0)
    if longest == 0:
        return f"`{text}`"
    run = "`" * (longest + 1)
    return f"{run} {text} {run}"


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

    # Every reply is authored by the account the token posts as, so a caller
    # that configured a user token re-triggers this action with its own
    # replies: the Bot prefilter only stops accounts GitHub marks Bot, and a
    # reply quoting `/unclaim` is then answered with itself forever. `/user`
    # is the token's own account where it has one, available before this
    # action has ever assigned on the issue — the assignment-event
    # attribution below needs an assignment the action already made, and the
    # loop has to be broken before the first reply, including on issues
    # assigned by hand. When the commenter is that account nothing is posted
    # and nothing is assigned, so the loop's first turn can never happen;
    # the decline is silent because a posted refusal would itself be the
    # next turn.
    identity = own_identity()
    # identity is None for one answer only: the token has no user account
    # behind it, because `/user` refused it with the documented
    # installation-token message — the default `${{ github.token }}` is an
    # App installation token, whose own comments are Bot-typed, so the User
    # check above has already refused the only account those replies could
    # come from and the loop is impossible without this comparison. Every
    # other `/user` failure ends the run inside own_identity, before
    # anything is posted or assigned, so reaching this comparison at all
    # already means an identity was established rather than assumed.
    #
    # GitHub logins are case-insensitive, and the comment event and /user
    # can spell one account with different letter cases; the comparison
    # folds both sides the way assignment_timeline's spellings map does.
    if identity is not None and actor.casefold() == identity.casefold():
        print("commenter is the token's own account: " + identity)
        return 0

    if not re.fullmatch(r"[0-9]+", issue):
        raise ValueError("invalid issue: expected digits")
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repo)
            or repo.split("/", 1)[1] in (".", "..")):
        raise ValueError("invalid repository: expected owner/name")

    raw = os.environ["MAX_CLAIMS"]
    # A value this run cannot read must fail it loudly rather than cap
    # nothing, cap the wrong role, or let a repeated entry win silently.
    # The single token -1 is the disabled default; every other value is a
    # comma-separated map of ROLE=CAP pairs.
    malformed = "invalid max-claims: expected -1 or comma-separated ROLE=CAP pairs"
    if raw == "-1":
        caps = None
    else:
        caps = {}
        for entry in raw.split(","):
            entry = entry.strip()
            if not re.fullmatch(r"[a-z]+=-?[0-9]+", entry):
                raise ValueError(malformed)
            role, _, cap_text = entry.partition("=")
            # Custom repository roles cannot be named (the README documents
            # the fold to the base level), so these five are the only keys.
            if role not in ("read", "triage", "write", "maintain", "admin"):
                raise ValueError(malformed)
            cap = int(cap_text)
            # Below -1 names no cap this action can act on, and a repeated
            # role would make the effective cap depend on entry order.
            if cap < -1 or role in caps:
                raise ValueError(malformed)
            caps[role] = None if cap == -1 else cap

    raw_expire = os.environ["EXPIRE"]
    # The same grammar as max-claims: the single token -1 is the disabled
    # default, so with nothing configured no expiry code runs at all. The
    # unit is days. A 0 would expire every claim the moment it is made, so
    # it is refused as loudly as every other value this run cannot read —
    # an empty value or a unit suffix fails the same way the max-claims map
    # fails its unparseable entries.
    malformed_expire = "invalid expire: expected -1 or a positive integer of days"
    if raw_expire == "-1":
        expire_days = None
    else:
        if not re.fullmatch(r"[0-9]+", raw_expire):
            raise ValueError(malformed_expire)
        expire_days = int(raw_expire)
        if expire_days == 0:
            raise ValueError(malformed_expire)

    endpoint = f"repos/{repo}/issues/{issue}"

    def say(body):
        # A reply too long for GitHub to accept is replaced by one the
        # commenter can act on rather than by its first MAX_COMMENT
        # characters: a reply cut where it lands says less than no reply.
        #
        # What makes that sentence correct here is that only the two replies
        # which quote the commenter's own body can get this far. Everything
        # else say() is handed is bounded by GitHub rather than by a stranger:
        # `@{actor}` is a login of at most 39 characters, and the assignee list
        # is at most ten of them. A reply built from anything else that a
        # commenter could grow would land in the same sentence and tell its
        # reader to type `/claim`, which would be wrong — so that is the thing
        # to check before adding one.
        #
        # The replacement is bounded by construction, so it never needs
        # replacing itself.
        if len(body) > MAX_COMMENT:
            body = (f"I could not answer that here: the answer would be longer "
                    f"than GitHub allows in a comment ({MAX_COMMENT} "
                    f"characters). Comment `/claim`, `/unclaim` or `/release` "
                    f"on its own, optionally followed by the issue number, for "
                    f"example `/claim {issue}` or `/claim #{issue}`.")
        # The body travels on stdin: a maximum-size comment does not fit in an
        # argument list, and an argv that cannot hold it takes the whole run
        # down with E2BIG before any API call is made. This is a different
        # failure from the ceiling above, which is about the body's length and
        # not about how it is carried; neither fix replaces the other.
        gh(f"{endpoint}/comments", "--input", "-", "--silent",
           stdin=json.dumps({"body": body}))

    # The number must share the command's line: a body with a newline is
    # prose, not a command followed by a number on the next line.
    match = re.fullmatch(r"(/claim|/unclaim|/release)(?:[ \t\v\f]+#?([0-9]+))?", command)
    # The replies below quote the command words, so a caller that triggers on
    # its own comments would answer its reply with itself; the token-identity
    # refusal above is what stops that, since a reply can never come from a
    # different account than the token posts as.
    if match is None:
        # A comment is an attempt at a command only where a line of it STARTS
        # with a command word — the word, then whitespace or the end of the
        # line. A word inside a URL, a path or a sentence is a mention, not
        # an attempt, and answering prose drew a reply to whatever line came
        # first: daedalus#1448's CI-log analysis was told "Not a command:
        # `## Which code failed...`" because line 31 held a release-asset
        # URL. CRs are already gone above, so a line ends at the newline and
        # a Windows client's `/claim\r` still ends with the word. The scan is
        # case-sensitive because the exact match above is. The topmost match
        # wins because it is the attempt the commenter made first, and the
        # reply names the line it was on rather than repeating the comment's
        # first line, which may hold no command word at all.
        for number, line in enumerate(command.split("\n"), 1):
            started = re.match(r"(/claim|/unclaim|/release)(?:[ \t\v\f]|$)", line)
            if started is None:
                continue
            word = started.group(1)
            # The line reaches two sinks that render control characters
            # instead of showing them: the Actions run log executes ANSI
            # escapes, and the reply carries the line into the posted
            # comment. Both take the \xNN spellings.
            escaped = control_escape(line)
            print(f"not a command: {word} on line {number}: {escaped}")
            # A backslash escape does not work inside a code span, so the
            # span's delimiter is a backtick run one longer than the longest
            # run in the line: a span closes only at a run of exactly equal
            # length, so nothing in the line can end it.
            quoted = quote_attempt(escaped)
            say(f"Not a command: `{word}` on line {number}: {quoted}. "
                "Comment one of `/claim`, `/unclaim` or `/release` on its "
                "own, optionally followed by the issue number, for example "
                f"`/claim {issue}` or `/claim #{issue}`.")
            return 1
        # No line even starts with a command word: nothing here is an attempt
        # to run one, and a reply to it would be a reply to prose. The run
        # ends quietly, the way a bot's comment is skipped.
        print("no line starts with a command word")
        return 0
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
            if expire_days is not None and assignees:
                # Privileged release of an expired claim: role first (the
                # same lookup the cap path does), then timeline → proof →
                # expiry → act. Anyone below write gets today's refusal with
                # no timeline call at all; so does an issue holding nothing,
                # which cannot have anything expired on it.
                role = actor_role(repo, actor)
                if role in ("write", "maintain", "admin"):
                    current = assignment_timeline(json.loads(
                        gh("--paginate", "--slurp",
                           f"{endpoint}/events?per_page=100")),
                        assignees)
                    if assignments_are_ours(current, assignees, identity):
                        expired, unreadable = expired_of(
                            current, assignees, expire_days)
                        if unreadable:
                            print("no readable age for: "
                                  + ", ".join(unreadable))
                        if expired:
                            for login, _ in expired:
                                # DELETE names exactly one login so every
                                # other assignee stays.
                                gh("-X", "DELETE", f"{endpoint}/assignees",
                                   "-f", f"assignees[]={login}", "--silent")
                            print("released expired claim of "
                                  + holders_log(expired))
                            say(release_reply(expired, actor))
                            return 0
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
            return 0
        # Takeover of an expired claim: proof → expiry → cap → act. The
        # proof runs first so an unattributable issue is never touched, the
        # expiry second so an in-window claim costs no role or search call,
        # the cap third so a takeover obeys the same limits a fresh claim
        # would — and whenever nothing proves expired, the refusal is
        # exactly the one today's code posts.
        expired = []
        if expire_days is not None:
            current = assignment_timeline(json.loads(
                gh("--paginate", "--slurp", f"{endpoint}/events?per_page=100")),
                assignees)
            if assignments_are_ours(current, assignees, identity):
                expired, unreadable = expired_of(current, assignees,
                                                 expire_days)
                if unreadable:
                    print("no readable age for: " + ", ".join(unreadable))
        if not expired:
            say(f"This issue is already claimed by {mention(assignees)}. "
                "Comment `/unclaim` (or `/release`) if you are giving it up.")
            return 0
        refusal = cap_reply(repo, actor, caps) if caps is not None else None
        if refusal is not None:
            say(refusal)
            return 0
        for login, _ in expired:
            # DELETE names exactly one login so every other assignee stays.
            gh("-X", "DELETE", f"{endpoint}/assignees",
               "-f", f"assignees[]={login}", "--silent")
        # The POST's own response is the only place this run can learn
        # whether ITS assignment was accepted — the same decline
        # discriminator the fresh-claim path below relies on.
        assigned = assignee_logins(json.loads(
            gh("-X", "POST", f"{endpoint}/assignees", "-f",
               f"assignees[]={actor}")))
        if actor not in assigned:
            say(f"GitHub would not accept @{actor} as an assignee here. "
                "That usually means the account needs to have commented on or been "
                "granted access to this repository.")
            return 1
        confirmed = assignee_logins(snapshot(endpoint))
        if actor not in confirmed:
            say(f"GitHub would not accept @{actor} as an assignee here. "
                "That usually means the account needs to have commented on or been "
                "granted access to this repository.")
            return 1
        print("took over expired claim of " + holders_log(expired))
        say(takeover_reply(expired, actor))
        return 0

    # An unnamed role and an explicit -1 both fall through: unlimited, no
    # search call. The cap governs only the /claim paths — fresh and
    # takeover alike — it never counts against, blocks or removes a manual
    # assignment.
    refusal = cap_reply(repo, actor, caps) if caps is not None else None
    if refusal is not None:
        say(refusal)
        return 0

    # Assigning is additive: a second claimant is added beside the first rather
    # than refused, so two runs that both read an empty assignee list can both
    # write and leave the issue held twice. The POST's own body is the only
    # place this run can learn whether ITS assignment was accepted — a peer
    # that removes this login before the re-read is then indistinguishable from
    # GitHub declining the assignee, and the run would blame the commenter's
    # account for a race it lost. The POST is reached only when the first
    # snapshot held nobody, so every assignee confirmed below arrived after
    # that read: the removals below reach only recent assignees, and only
    # when every one of them is a write the action made itself.
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
    # the same list, and any rule over the list alone breaks one of them.
    # Every quantity below is a function of the whole confirmed set, so two
    # runs reading the same state settle it the same way. Nothing here may be
    # derived from which login is running: a partition that depends on that is
    # not one the other run shares, and the two runs then take opposite
    # branches of the same state. If every confirmed assignee's current
    # assignment was made by the same identity, and that identity is this
    # action's own — the account the token writes as, or, for an installation
    # token, its Bot account — the earliest of them wins; if not, a write
    # this action cannot claim is among them and the action cannot say
    # which, so it does nothing. The earliest assignment is the one no run
    # removes, so the first
    # claimant is permanent; every later one is removed by a run that read it
    # beside an earlier claim, or by its own run, and a run that never reaches
    # its own re-read is removed by whichever run does reach one while the
    # contest is still live, and by nothing else.
    current = assignment_timeline(json.loads(
        gh("--paginate", "--slurp", f"{endpoint}/events?per_page=100")),
        confirmed)
    # One shared identity is still not attribution: it has to be THIS
    # token's own write. With a user identity the events' actor login must
    # be it, in either letter case; with no user identity the token is an
    # App installation, whose writes are exactly its Bot-typed account. A
    # maintainer who hand-assigned every holder inside the window shares one
    # identity that is neither, and nothing is removed — their assignment is
    # not the action's to take away. The tie-break and the expiry paths
    # prove this through the same helper, so the three can never drift.
    if not assignments_are_ours(current, confirmed, identity):
        # A login with no readable current event, identities that do not all
        # agree, or an agreement that names somebody else: the writes on this
        # issue cannot be attributed to this action, and changing nothing is
        # the only answer that cannot destroy an assignment the action did
        # not make.
        others = [login for login in confirmed if login != actor]
        if actor in confirmed:
            advice = ("Comment `/unclaim` (or `/release`) if you are giving up "
                      "yours.")
        else:
            # `/unclaim` would answer that there is nothing to give up, which
            # is the one thing this commenter does not need to be told twice.
            advice = "You are not assigned to this issue."
        say(f"@{actor} this issue is assigned to {mention(others)}. This run "
            f"could not prove every assignment on it was made by this "
            f"action, so no assignment was changed. {advice}")
        return 1

    # (id, login) is a total order, so two events sharing an id settle the same
    # way in every run rather than leaving a pair behind.
    def order(login):
        return (current[login]["id"], login)

    winner = min(confirmed, key=order)
    removed = sorted((login for login in confirmed if login != winner), key=order)
    for login in removed:
        # DELETE names exactly one login so every other assignee stays.
        gh("-X", "DELETE", f"{endpoint}/assignees",
           "-f", f"assignees[]={login}", "--silent")
    if winner != actor:
        say(f"You and @{winner} claimed this issue at the same time, and "
            f"@{winner} holds it, so your claim was released.")
        return 0
    # `removed` cannot be empty here: it is everyone but the winner out of a
    # confirmed list of two or more, since confirmed == [actor] returned above.
    # The branch is kept so that a future narrowing which empties it posts no
    # winner's claim rather than one the issue does not have.
    if removed:
        were = "were" if len(removed) > 1 else "was"
        that = ("those assignments were" if len(removed) > 1
                else "that assignment was")
        say(f"Assigned to @{actor}. {mention(removed)} {were} assigned at the "
            f"same time, so {that} removed.")
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
    except OSError as error:
        # A failure to reach the API at all — no gh to execute, a descriptor
        # closed under it — is news about this run, and a run log is where a
        # maintainer reads news. This reports it in the same terms as the
        # refusals above; it does not answer the comment that provoked it, and
        # no exception handler here can.
        print(f"could not reach the API: {error}", file=sys.stderr)
        sys.exit(1)
