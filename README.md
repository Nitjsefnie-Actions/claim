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
comment is on. Carriage returns are removed for Windows clients. A command
inside a sentence is a sentence: `please /claim this` is declined like any
other non-command. Commands are case-sensitive.

Anything else is declined loudly: the action posts a reply on the issue
naming the offending line and the accepted forms, and the run fails, so a
refused command is visible to the commenter and on the issue instead of a
silent green run. A command carrying a different issue's number, and a
command on a closed issue or a pull request, is declined the same way.

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
      - uses: Nitjsefnie-Actions/claim@10f882ee4dc5cd39b7d3cbcbf151902d6427b53f
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

<<<<<<< HEAD
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
>>>>>>> 0d9bffc (docs(readme): say what a tie settles, and what it cannot)

The job's `if:` is only a prefilter to save starting a runner. The action
re-checks all three conditions itself: the target is an issue rather than a
pull request, the issue is open, and the commenter is not a bot. The
`contains()` checks also only prefilter: the action performs the exact command
match itself.

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

For a recognized command, a non-`User` account type is refused with a log
diagnostic. An empty `actor-type` fails the run as a configuration error; its
default comes from the comment event, so other event types need an explicit
value for this input.

## What it will not do

- Act on a closed issue, including releasing an assignment after closure.
- Act on a pull request.
- Act on a bot's comment.
- Treat an inexact body as a command.
- Stay silent about a refusal: every decline a human can act on is answered
  on the issue, and the run fails.
- Claim an issue somebody already holds or replace its assignees. If the
  commenter already holds it, the action says so without changing assignments.
  Two claims landing in the same instant are the one case that removes an
  assignment: the issue is left with whoever the issue's assignment events
  record as assigned **first** — the order comes from those events, not from
  the commenter list and not from any alphabetical rule — and the other
  commenter is told it lost and who holds the issue. Every assignment the
  action removes has to have been made by the same identity, because that is
  the only thing that makes it one of the action's own writes. If the
  assignees do not all share one identity — somebody assigned this issue by
  hand in the same window, or an event is not yet readable — it cannot tell
  which one is not its own, so it removes nothing at all and says so on the
  issue. Nothing it does depends on which commenter is running, so two runs
  that read the same state always settle it the same way.

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
