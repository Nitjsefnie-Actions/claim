# Contributing to claim

Issues and pull requests are welcome — especially ones that show the action
assigning, refusing or announcing something other than what `README.md` says it
does. This action runs with a token that can write to an issue tracker, driven
by a comment body a stranger wrote, so a report that says "this treats X as a
command and it should not, here is the body" is the most valuable thing you can
send.

## LLM and agent contributions are welcome

You may use an LLM or a coding agent to write your contribution. There is no
penalty, no separate review queue, and no expectation that you rewrite its
output by hand. Much of this repo was built that way.

Two conditions, and they are about honesty rather than provenance:

1. **Disclose the model** with a trailer on each commit it authored:

   ```
   Co-Authored-By: <Model Name> <noreply@example.com>
   ```

   e.g. `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. The plain
   model name — a context-window suffix like `(1M context)` is not part of it.
   One primary-author trailer per commit.

   Before pushing, inspect every outgoing commit rather than checking only the
   tip:

   ```bash
   git log --format='%h %(trailers:key=Co-Authored-By,valueonly)' origin/main..HEAD
   ```

   A present trailer is not enough: its value must exactly match the model's
   standardized identity. For GPT-6 Astra that identity is
   `GPT-6 Astra <noreply@openai.com>`; slug, case, and hyphen variants such as
   `gpt-6-astra` and `GPT-6-Astra` are not equivalent.

2. **Do not submit claims you have not verified.** Paste the command and its
   real output. "Tests pass" without the run is not evidence, and a shell
   script is unusually easy to be confidently wrong about: quoting, word
   splitting and `sed` dialects all part company with the obvious reading
   quietly, and a stub that answers every call the same way passes a suite that
   proves nothing.

If a maintainer's reply reads like it was drafted by an agent, it probably was.
That is fine in both directions.

## A new file is invisible until you name it

`.gitignore` denies by default: it starts with `*` and names back exactly what
the repository ships. A file you create is **untracked and unstaged and will
not appear in `git status`** until it is named there. Git never looks inside a
directory it has already ignored, so re-open the directory before naming its
contents:

```
*
!tests/
tests/*
!tests/*.sh
```

Prove a change to it rather than reading it: seed a junk file in the directory
you changed, check `git check-ignore -v` refuses that file, and check
`git status --porcelain` is clean with every shipped file tracked.

## Getting it running

Nothing to install but `shellcheck`. `bash`, `gh` and `jq` are what the action
itself needs, and every GitHub-hosted runner has all three.

```bash
tests/run.sh          # the whole suite; its exit status is the verdict
shellcheck claim.sh tests/*.sh
```

The suite runs `claim.sh` as a real subprocess with a stub `gh` earliest on
`PATH`, so a case can assert both the API calls that were made and the ones
that were not. There is no framework and no dependency to install; if a case
needs a new fixture, add it beside the others.

You cannot exercise the action end to end without a repository to install it
in. Point a scratch repository's workflow at your branch —
`uses: <your-fork>/claim@<your-branch>` — and comment on a real issue there.

## House style

- **Comments explain why, not what.** Nearly every line of `claim.sh` is
  defending against something invisible from the code — GitHub silently
  ignoring an assignee it will not accept, a comment body carrying carriage
  returns from a Windows client, a `DELETE` that must name exactly one login so
  a second assignee survives. If you change such a line, change the comment
  with it.
- **The comment body is data, never program text.** It reaches the script
  through the environment and is never interpolated into a shell command or
  into a `run:` block. A patch that puts `${{ github.event.comment.body }}`
  inside a `run:` will be refused whatever else it does.
- **Tests pin behaviour, not implementation.** A test that would still pass
  with the bug reintroduced is not worth adding. Break the line you are
  protecting, watch the case fail, restore it — and say in the pull request
  which case failed and what it printed.

## Issues

Use the [issue form](.github/ISSUE_TEMPLATE/issue.md). Its section order is
fixed and its **Description is observed behaviour only** — what is actually
wrong, not the mechanism and not the fix. A proved mechanism still goes under
Suggested Fix, marked unverified. That is not pedantry: a report whose
description is a hypothesis sends the reader to the wrong place when the
hypothesis is wrong, and it often is.

Not reliably reproducible? Drop the Reproduction Steps section entirely and say
so in the description, rather than writing steps that do not trigger it.

Something exploitable — a body this action treats as a command when it should
not, a way to make it write to an issue the commenter should not reach — goes
to a [security advisory](https://github.com/Nitjsefnie-Actions/claim/security/advisories/new),
not the tracker.

### Claim it before you start

Comment `/claim` on an open, unassigned issue and this repository's own
[`claim` workflow](.github/workflows/claim.yml) assigns you, no write access
needed. It runs this action against this repository, so a claim that does not
work is itself a bug report.

The body must be exactly the command after trimming, so "I'll `/claim` this
one" is ignored, as are a closed issue, a pull request, a bot, and an issue
somebody already holds. Re-read the issue afterwards and confirm your login is
in `assignees`: a posted comment is not a claim.

Release an issue you stop working, before the merge that closes it — the action
acts on open issues only, so a stale assignment on a closed one can no longer
be removed.

## Pull requests

Small and single-purpose beats large and comprehensive. One logical change per
commit, with a message that says what changed and why the previous behaviour
was wrong.

Claim the issue before you start, then name it in the pull request's
**Related Issues and Pull Requests** section.

In the description, include what changed, why, and the actual output of the
tests you ran.

If you find a second defect while fixing the first, **file it** rather than
folding it in. A commit that fixes two things is a commit that cannot be
reverted for one of them.
