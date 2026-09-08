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
surrounding whitespace, including blank lines. Carriage returns are removed
for Windows clients. A command inside a sentence is a sentence:
`please /claim this` does nothing. Commands are case-sensitive.

## Install

Save this complete workflow as `.github/workflows/claim.yml` on your
repository's default branch. The action is consumed by its permanent commit
SHA.

```yaml
name: claim
on:
  issue_comment:
    types: [created]
permissions:
  issues: write
concurrency:
  group: claim-${{ github.event.issue.number }}
  cancel-in-progress: false
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
    steps:
      - uses: Nitjsefnie-Actions/claim@10f882ee4dc5cd39b7d3cbcbf151902d6427b53f
```

`issue_comment` with `types: [created]` handles newly posted comments; editing
an old comment does not trigger a claim. The job runs on Ubuntu with a
five-minute timeout.

The narrow `permissions:` block grants the token only `issues: write`, which
is needed to read issues, change assignees, and post replies. The action never
reads the repository tree, so the calling workflow needs neither
`contents: read` nor a checkout step. The default `github.token` is sufficient.

The per-issue `concurrency:` group serializes competing claims so they do not
both act on the same unassigned snapshot. `cancel-in-progress: false` is
deliberate: when two people claim at once, both must get an answer instead of
one run being cancelled halfway through an assignment.

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

## What it will not do

- Act on a closed issue, including releasing an assignment after closure.
- Act on a pull request.
- Act on a bot's comment.
- Treat an inexact body as a command.
- Claim an issue somebody already holds or replace its assignees. If the
  commenter already holds it, the action says so without changing assignments.

A posted command comment is **not proof of a claim**. GitHub can silently
decline an assignment; the action catches that with a confirming re-read and
posts its answer as a comment on the issue. A declined assignment also fails
the run. Check that your login actually appears in the issue's assignees.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the suite and contribution process,
and [SECURITY.md](SECURITY.md) for private vulnerability reporting.
Licensed under the [MIT License](LICENSE).
