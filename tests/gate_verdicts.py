#!/usr/bin/env python3
"""The commit-scope gate, run as the shellcheck job runs it over planted states.

The fixture holds this tree's tracked files and a bare origin. Only the exit
status is read, and a crash exits non-zero too, so each refusal sits between
greens on the same fixture.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def git(tree, *args):
    return subprocess.run(("git", "-C", str(tree), *args), check=True,
                          capture_output=True, text=True).stdout


def commit(tree, path, subject):
    with open(tree / path, "a", encoding="utf-8") as handle:
        handle.write(f"a change for {subject}\n")
    # -f: the copied .gitignore denies by default, NOTES.md included.
    git(tree, "add", "-f", "--", path)
    git(tree, "commit", "--quiet", "-m", subject)


def fixture(root, where):
    tree = where / "tree"
    listed = git(root, "ls-files", "-z").split("\0")
    for name in filter(None, listed):
        (tree / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, tree / name)
    git(where, "init", "--quiet", "--bare", "origin.git")
    git(tree, "init", "--quiet", "--initial-branch=main")
    git(tree, "config", "user.email", "fixture@example.invalid")
    git(tree, "config", "user.name", "fixture")
    git(tree, "add", "-A", "-f")
    git(tree, "commit", "--quiet", "-m", "base tree")
    git(tree, "remote", "add", "origin", str(where / "origin.git"))
    git(tree, "push", "--quiet", "origin", "main")
    return tree


class Gate:
    def __init__(self, tree, script):
        self.tree, self.script, self.failed = tree, script, False

    def expect(self, state, refuses):
        ran = subprocess.run((sys.executable, f"tests/{self.script}"),
                             cwd=self.tree, capture_output=True, text=True,
                             env={**os.environ, "GITHUB_EVENT_NAME": "pull_request"})
        if (ran.returncode != 0) != refuses:
            self.failed = True
            wanted = "a non-zero exit" if refuses else "exit 0"
            print(f"  {self.script}, {state}: expected {wanted}, "
                  f"got {ran.returncode}\n{ran.stdout}{ran.stderr}")


def scopes(tree):
    gate = Gate(tree, "commit_scopes.py")
    gate.expect("an empty outgoing range", refuses=False)
    git(tree, "checkout", "--quiet", "-b", "head-branch")
    commit(tree, "NOTES.md", "fix(tests): pin a change")
    for subject, refuses in (("fix(tests): pin a change", True),
                             ("test(harness): pin a change", False),
                             ("ci(tests): pin a change", False),
                             ("fix(claim): pin a change", False)):
        git(tree, "commit", "--quiet", "--amend", "-m", subject)
        outgoing = git(tree, "log", "--format=%s", "origin/main..HEAD")
        if outgoing != f"{subject}\n":
            raise SystemExit(f"  the outgoing range is not {subject!r}: {outgoing!r}")
        gate.expect(subject, refuses)
    return gate.failed


def main(argv):
    root, check = Path(argv[1]), {"scopes": scopes}[argv[2]]
    with tempfile.TemporaryDirectory() as where:
        return 1 if check(fixture(root, Path(where))) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
