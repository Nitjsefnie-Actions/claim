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
      github.event.comment.user.type != 'Bot'
      && (contains(github.event.comment.body, '/claim')
          || contains(github.event.comment.body, '/unclaim')
          || contains(github.event.comment.body, '/release'))
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      issues: write
    steps:
      - uses: Nitjsefnie-Actions/claim@6ae0d102c79d2feec867520795b318b7ca33904a # v2.0.0
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
Stock actionlint 1.7.12 — the current upstream release, which many
repositories run as a required gate — does not know this key and rejects
the workflow with `unexpected key "queue" for "concurrency" section`. If
that gate is yours, the ways out are an `ignore` pattern scoped to that one
finding (the `-ignore` flag, or the `ignore` list under `paths:` in the
actionlint config file — the inline `# actionlint: ignore` comment does not
silence this one) or a patched build: Nitjsefnie-OSC/actionlint carries
upstream rhysd/actionlint#654 as v1.7.12-queue.1, which accepts the block.
Dropping `queue:` also passes, returning the block to the default
single-pending-run queue described above.

That group is per repository and per workflow, though, so a caller without
that exact group — or with it under another name — gets no protection from it.
The action therefore settles a tie itself rather than depending on the group.

The job's `if:` is only a prefilter to save starting a runner. It checks
two things: that the commenter is not a bot, and that the comment contains
a command word. The closed-issue and pull-request conditions are enforced
by the action itself, and both declines are loud — a reply naming the
command word and a failed run — where a job-level condition would skip the
run before any reply could be posted. The loose prefilter starts a runner
for a command on a closed issue or a pull request too, which the action
then declines loudly. The `contains()` checks also only prefilter: the
action performs the exact command match itself. Those checks stay loose on
purpose. The accepted forms include a body with leading whitespace or a
leading blank line, which a `startsWith()` on the raw body would refuse to
start a run for — GitHub's expression language has no `trim`, so a caller
cannot strip first, and a valid command would be one the action could
never see. A comment no line of which starts with a command word still
ends quietly, and a bot's comment still never starts a runner.

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
| `expire` | `-1` | Days before an idle claim expires (see below). `-1` never expires. |

For a recognized command, a non-`User` account type is refused with a log
diagnostic. An empty `actor-type` fails the run as a configuration error; its
default comes from the comment event, so other event types need an explicit
value for this input. A comment posted by the account the `token` posts as is
declined in the run log only, because a reply would re-trigger the very
workflow that configured the token. Declining that comment means comparing it
against the account the `token` writes as, which the action looks up before it
does anything else, and the lookup has outcomes of its own:

- a `token` that answers with its login — the comparison is made against it,
  and a comment from that account is declined;
- the default `${{ github.token }}`, an App installation token with no account
  of its own, which GitHub refuses with `Resource not accessible by
  integration` — that one refusal means "there is no account to compare
  against", so the run carries on and every comment is processed normally;
- anything else — a rate limit, a network error, a `5xx`, a `401`, a refusal
  saying something other than the one above, or a `200` whose body carries no
  login — which fails the run before anything is posted or assigned, because
  an action that cannot say which account its own `token` writes as must not go
  on to answer a comment from that account. The run log says so and carries
  what `gh` reported.

### Per-role claim caps

`max-claims` caps how many open issues one account may hold claims on,
per repository role. The value is either `-1` alone — the default, which
disables the cap entirely: no role lookup, no search call, behavior
exactly as before this input existed — or a comma-separated map of
`ROLE=CAP` pairs; whitespace around an entry — spaces or tabs — is
stripped and ignored, while whitespace inside an entry, around the
`=` or inside the role or the cap, is refused:

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

### Claim expiry

`expire` retires an idle claim. The value is `-1` — the default, which
disables expiry entirely: no expiry code runs, no extra API call is made,
and the behavior is exactly what it was before this input existed — or a
positive integer counting days. `0` would expire every claim the moment it
is made, so it is refused loudly (the run fails) like every other value the
action cannot read: `-2`, `7d`, `abc`, an empty string.

Expiry is lazy. It is evaluated inside the run that answers a comment —
never by a sweep, a schedule or a second workflow mode. A `/claim` that
lands on an unassigned issue never touches the timeline at all.

The age of a claim is the `created_at` of its holder's **current**
`assigned` event — the same `--paginate` replay of the issue's events the
tie-break reads — and a claim expires when it has been held **strictly**
longer than `expire` days: held exactly 7.0 days with `expire: 7` is not
expired yet. An event whose `created_at` is missing or unreadable leaves
the age unestablished: the claim counts as not expired, nothing is
removed, and the run log names the holder whose age could not be read.

Only claims this action itself made can expire. Every holder's current
assignment must be provably a write of the action's own account — the
login the token posts as, or, for the default `github.token`, its
Bot-typed account — which is the same proof the tie-break uses. A manual
assignment anywhere among the holders defeats the takeover and the
privileged release however ancient the claim looks: the action does not
remove assignments it did not make.

Two things may then happen to an expired claim:

- **Takeover.** Any commenter may `/claim` an issue whose claim has
  expired: each expired holder is unassigned, the commenter is
  assigned in their place, and the reply names each expired holder with
  its age — `The expired claim of @alice (held 8 day(s)) has been taken
  over by @bob.` The takeover obeys the same per-role cap as a fresh
  claim (a `0` cap, or a reached finite cap, refuses with the same
  replies and removes nothing); the cap is read only after expiry, so an
  in-window claim costs no role or search call. Holders whose claims have
  not expired — or whose age could not be read — keep their claims and
  stay assigned beside the new claimant.
- **Privileged release.** A commenter whose repository role (`role_name`,
  the same lookup the cap uses) is `write`, `maintain` or `admin` may
  `/release` (or `/unclaim`) someone else's expired claim; `read` and
  `triage` are refused exactly as today, without the timeline read. The
  reply names who acted and who held how long — `@bob has released
  @alice's expired claim (held 8 day(s)).`

Ages in replies are whole days, rounded down.

## What it will not do

- Act on a closed issue, including releasing an assignment after closure.
- Act on a pull request.
- Act on a bot's comment.
- Answer a comment posted by the account its `token` posts as. The run
  declines in the run log only, because a reply would re-trigger a caller
  that configured a user token and answer itself forever. That decline holds
  only while the action can establish which account the `token` writes as:
  it fails the run before anything is posted or assigned when that lookup
  fails for any reason other than the documented installation-token refusal,
  which means there is no account behind the `token` to compare against (see
  [Inputs](#inputs)).
- Treat an inexact body as a command.
- Stay silent about anything that is not an attempt: a comment no line of
  which starts with a command word — a URL or a sentence that merely
  mentions one — gets no reply and a green run. Every declined attempt is
  answered on the issue, and the run fails.
- Claim an issue where nothing is provably expired: while every claim on
  it is still inside its `expire` window, when the assignments cannot be
  proven to be the action's own, and when a holder's age cannot be read —
  whatever the claim's age. If the commenter already holds it, the
  action says so without changing assignments. Two claims landing in the
  same instant, and the takeover of an expired claim (above), are the only
  cases that remove somebody else's assignment; a `/unclaim` removes only
  the commenter's own.
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

## If nothing happens

You posted a command and nothing happened. Work down this list.

- **Find the run for your comment.** The workflow listens for newly created
  comments, so every newly created comment starts a run; a comment with no
  command word shows a skipped run. No run at all means the workflow is not
  running — disabling a workflow stops it being triggered — so check in the
  Actions tab that the workflow is enabled (its page offers Enable workflow
  when it is not) and that the workflow file sits on the default branch.
- **The run sits in Queued.** That is normal under load: the per-issue
  concurrency group serializes competing claims, `queue: max` keeps up to
  100 pending runs in first-in, first-out order, and each run is bounded
  by a five-minute timeout, so the queue drains.
- **The run failed.** Read its log. Every declined attempt fails the run
  and posts a reply on the issue; an API failure posts no reply at all. A
  red run with no reply on the issue died before it could post one, and
  the log names where. The log line
  `gh: Resource not accessible by integration (HTTP 403)` is the
  token-permission signature: check the job's `permissions:` block grants
  `issues: write` (the default `github.token` is sufficient).
- **The run succeeded and posted no reply.** By design, in three cases: the
  comment never started a line with a command word (a prose mention), the
  commenter is the token's own account, or the commenter's account type is
  not `User`. The last two are declined in the run log only, and a bot's
  comment never even starts the job.
- **The run succeeded and a reply was posted.** The reply names the
  outcome — a tie lost to another commenter, a cap refusal, an issue
  already held — and what proves the claim is the standing check: your
  login in the issue's assignees. [What it will not do](#what-it-will-not-do)
  carries the standing guidance.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the suite and contribution process,
and [SECURITY.md](SECURITY.md) for private vulnerability reporting.
Licensed under the [MIT License](LICENSE).
