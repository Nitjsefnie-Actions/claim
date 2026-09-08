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
