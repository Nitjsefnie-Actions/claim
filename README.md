# claim

Let contributors take an issue with a comment, without repository write access.
GitHub's built-in slash commands do not include assignment, so without this
action a contributor with no write access cannot take an issue themselves:
someone with write access has to use the assignee control for them.

## Commands

- `/claim` assigns the commenter to an open, unassigned issue.
- `/unclaim` removes the commenter's **own** assignment and nobody else's.
- `/release` is another name for `/unclaim`, with exactly the same behavior.

The entire comment body must be **exactly** one command after trimming
surrounding whitespace, including blank lines, optionally followed by the
issue's number with or without `#`: on issue 7, `/claim`, `/claim 7` and
`/claim #7` are the same command. A carried number must name the issue the
comment is on. Carriage returns are removed for Windows clients. Commands
are case-sensitive.

A comment that never starts a line with a command word is not an attempt to
run one: a command word inside a URL, a path or a sentence — `please /claim
this`, a `/releases/` link — gets no reply, and the run ends quietly, the
same way a bot's comment is skipped.

A line that does start with a command word makes the comment an attempt, and
a failed attempt is declined loudly: the action posts a reply naming the
command word and quoting the line it was on, with the accepted forms, and
the run fails, so a refused command is visible to the commenter and on the
issue instead of a silent green run. A command carrying a different issue's
number, and a command on a closed issue or a pull request, is declined the
same way.

## Install

Save this complete workflow as `.github/workflows/claim.yml` on your
repository's default branch. The action is consumed by its permanent commit
SHA.

```yaml
name: claim
on:
  issue_comment:
    types: [created]
concurrency:
  group: claim-${{ github.event.issue.number }}
  cancel-in-progress: false
  queue: max
jobs:
  claim:
    if: >-
      github.event.issue.pull_request == null
      && github.event.issue.state == 'open'
      && github.event.comment.user.type != 'Bot'
      && (contains(github.event.comment.body, '/claim')
          || contains(github.event.comment.body, '/unclaim')
          || contains(github.event.comment.body, '/release'))
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      issues: write
    steps:
      - uses: Nitjsefnie-Actions/claim@ceaadaa096fd249cdeecc137342158ec17347cb9 # v1.1.0
```

`issue_comment` with `types: [created]` handles newly posted comments; editing
an old comment does not trigger a claim. The job runs on Ubuntu with a
five-minute timeout.

The job's `permissions:` block grants the token only `issues: write`, which
is needed to read issues, change assignees, and post replies. On a one-job
workflow, job level is the narrower equivalent of the same scope at workflow
level: it applies only while the job runs. Workflow-level write scopes are
what least-privilege audits flag — zizmor's pedantic persona reports the
placement this block replaced as `excessive-permissions`. The action never
reads the repository tree, so the calling workflow needs neither
`contents: read` nor a checkout step. The default `github.token` is sufficient.

The per-issue `concurrency:` group serializes competing claims so they do not
both act on the same unassigned snapshot. `cancel-in-progress: false` is
deliberate: when two people claim at once, both must get an answer instead of
one run being cancelled halfway through an assignment. The default queue also
keeps only a single pending run per group and cancels it when a newer claim
arrives, so the third claim on a busy issue would silently leave the second
claimer without an answer. `queue: max` instead keeps up to 100 pending runs
in first-in, first-out order — GitHub's documented cap — and cancels any
further run once the queue is full. The ordering follows when each run
started waiting, and GitHub notes it is not guaranteed. It cannot be
combined with `cancel-in-progress: true`, which this block never sets.

That group is per repository and per workflow, though, so a caller without
that exact group — or with it under another name — gets no protection from it.
The action therefore settles a tie itself rather than depending on the group.

The job's `if:` is only a prefilter to save starting a runner. The action
re-checks all three conditions itself: the target is an issue rather than a
pull request, the issue is open, and the commenter is not a bot. The
`contains()` checks also only prefilter: the action performs the exact command
match itself. Those checks stay loose on purpose. The accepted forms include
a body with leading whitespace or a leading blank line, which a
`startsWith()` on the raw body would refuse to start a run for — GitHub's
expression language has no `trim`, so a caller cannot strip first, and a
valid command would be one the action could never see. A loose prefilter
only starts a runner for a comment the action then ends quietly.

## Inputs

All inputs are optional. Keep the event-derived defaults for ordinary use;
when overriding them, the caller is responsible for supplying the actual
commenter's identity and the issue and body from that comment event.

| Input | Default | Meaning |
| --- | --- | --- |
| `token` | `${{ github.token }}` | GitHub token with `issues: write`. |
| `repository` | `${{ github.repository }}` | Repository in `owner/name` format. |
| `issue` | `${{ github.event.issue.number }}` | Issue number. |
| `actor` | `${{ github.event.comment.user.login }}` | Commenter's login. |
| `actor-type` | `${{ github.event.comment.user.type }}` | Commenter's GitHub account type. |
| `body` | `${{ github.event.comment.body }}` | Comment body containing the command. |
| `max-claims` | `-1` | Per-role caps on concurrent claims, as comma-separated `ROLE=CAP` pairs (see below). `-1` alone disables the cap. |

For a recognized command, a non-`User` account type is refused with a log
diagnostic. An empty `actor-type` fails the run as a configuration error; its
default comes from the comment event, so other event types need an explicit
value for this input. A comment posted by the account the `token` posts as is
declined in the run log only, because a reply would re-trigger the very
workflow that configured the token.

### Per-role claim caps

`max-claims` caps how many open issues one account may hold claims on,
per repository role. The value is either `-1` alone — the default, which
disables the cap entirely: no role lookup, no search call, behavior
exactly as before this input existed — or a comma-separated map of
`ROLE=CAP` pairs, an optional space after each comma and no spaces
inside an entry:

```yaml
with:
  max-claims: 'read=2, triage=4, write=6, maintain=10, admin=-1'
```

Roles are exactly `read`, `triage`, `write`, `maintain` and `admin`. A
cap is `-1` (explicitly unlimited), `0` (the role cannot claim at all),
or a positive integer. Any other negative, a non-integer, an unknown
role, or a duplicate role is refused loudly and the run fails. A role
the map does not name is unlimited.

The role is the `role_name` the collaborators/permission endpoint
reports for the commenter, read with the default token: a total
stranger answers `role_name` `read`, so outsiders fall under `read`. A
custom repository role counts as its folded base level — the
endpoint's `permission` field, where `triage` folds to `read` and
`maintain` to `write` — because custom role names cannot be named in
the map.

At or above a role's finite cap the action counts the commenter's open
assigned issues in this repository with the search API and refuses with
a reply on the issue naming the role, the cap and the count; refusals
exit 0. A `0` cap replies that claiming is disabled for the role and
that a maintainer can still assign by hand. The cap governs only this
action's `/claim` path: it never counts against, blocks or removes a
manual assignment. The search index is eventually consistent, so a
burst of rapid claims can land one or two past a finite cap before it
catches up.

## What it will not do

- Act on a closed issue, including releasing an assignment after closure.
- Act on a pull request.
- Act on a bot's comment.
- Answer a comment posted by the account its `token` posts as. The run
  declines in the run log only, because a reply would re-trigger a caller
  that configured a user token and answer itself forever.
- Treat an inexact body as a command.
- Stay silent about anything that is not an attempt: a comment no line of
  which starts with a command word — a URL or a sentence that merely
  mentions one — gets no reply and a green run. Every declined attempt is
  answered on the issue, and the run fails.
- Claim an issue somebody already holds or replace its assignees. If the
  commenter already holds it, the action says so without changing assignments.
  Two claims landing in the same instant are the one case that removes
  somebody else's assignment; a `/unclaim` removes only the commenter's own.
  The issue is then left with whichever login's **current** assignment event
  comes first. The order comes from those events and never from the commenter
  list: a login assigned, unassigned and reassigned inside the window is
  ordered by the reassignment rather than by its original assignment, and two
  current events sharing an id are broken by login, so that two runs reading
  the same state cannot leave the issue with two holders. The other commenter
  is told it lost and who holds the issue. Every assignment the action removes
  has to have been made by the action's own account: with a user token the
  shared identity must be the login the token writes as, and with the default
  token it must be the Bot account an installation writes as. When the
  assignees do not all share one identity, an event is not yet readable, or
  the identity they share is not the action's own, it removes nothing at all
  and says so on the issue. The winner and the removals are computed from the
  confirmed set and its timeline alone, so two runs that read the same state
  leave the issue with the same login — what each run posts about it is the
  one thing that depends on which commenter is running.
- Exceed a per-role cap on concurrent claims when `max-claims` names a
  cap for the commenter's role: the count comes from the search API,
  which is eventually consistent, so a burst of rapid claims can land a
  claim or two past the cap before the index catches up. The action
  counts only open issues in the repository being claimed, and the cap
  never counts against, blocks or removes a manual assignment.

A posted command comment is **not proof of a claim**. GitHub can silently
decline an assignment; the action catches that with a confirming re-read and
posts its answer as a comment on the issue. That same re-read settles a tie: if
another `/claim` was assigned in the same moment, the issue is left with one
assignee and every run that reaches its re-read says which of the two holds it.
A write that lands after every other run's re-read leaves a pair that nothing
settles, so keep `cancel-in-progress: false` in the concurrency group above.
Like every decline, a declined assignment also fails the run. Check that your
login actually appears in the issue's assignees.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the suite and contribution process,
and [SECURITY.md](SECURITY.md) for private vulnerability reporting.
Licensed under the [MIT License](LICENSE).
