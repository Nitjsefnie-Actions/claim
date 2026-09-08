# Security

Report vulnerabilities privately through a
[security advisory on this repository](https://github.com/Nitjsefnie-Actions/claim/security/advisories/new),
not the public issue tracker. Include the action commit SHA, calling workflow,
comment body, and observed behavior needed to reproduce the problem.

In scope are the action, its handling of comment events and inputs, and the
repository's workflows, particularly unauthorized assignment or issue writes.
The comment body is attacker-controlled text and must never reach a shell as
program text: it must remain data passed through the environment.

The highest-value reports show a comment body being executed, or the action
writing to an issue on behalf of someone who did not comment. Reproduce only
in a repository you control.

## What happens after you report

A report is acknowledged within three working days. That acknowledgement is a
person confirming they have read it, not a verdict — the assessment follows.

You will get an assessment within ten working days: whether it reproduces, what
it affects, and if it is accepted, a rough idea of when a fix will land. If it
takes longer than that, you will be told why rather than left waiting.

Disclosure is coordinated with you. A fix is released before any public
description, and the advisory credits you unless you ask otherwise. Ninety days
after the report is the point at which disclosure happens regardless, so a
report cannot be buried by being left unanswered.

If a report is declined, you will be told the reason. Disagreeing with that is
reasonable, and saying so is welcome.
