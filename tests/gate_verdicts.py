#!/usr/bin/env python3
"""The base-freshness and commit-scope gates, run over planted states.

Each gate runs as the shellcheck job runs it, `python3 tests/<script>`, from a
fixture repository holding this working tree's tracked files and a bare
origin, under `GITHUB_EVENT_NAME=pull_request` whatever event runs the suite.
Only the exit status is read. A gate that crashes exits non-zero too, so each
refusal sits between greens on the same fixture: the state before it and the
repair after it.
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


def freshness(tree):
    gate = Gate(tree, "gate_base_freshness.py")
    gate.expect("the head is main", refuses=False)
    git(tree, "checkout", "--quiet", "-b", "head-branch")
    commit(tree, "BRANCH.md", "work main does not hold")
    for path, subject, refuses in (
            ("NOTES.md", "a file no required check names", False),
            ("tests/run.sh", "a file a required check names", True)):
        git(tree, "checkout", "--quiet", "main")
        commit(tree, path, subject)
        git(tree, "push", "--quiet", "origin", "main")
        git(tree, "checkout", "--quiet", "head-branch")
        gate.expect(f"main gained {subject}", refuses)
    git(tree, "rebase", "--quiet", "main")
    gate.expect("the head rebased onto main", refuses=False)
    return gate.failed


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
    root, check = Path(argv[1]), {"freshness": freshness, "scopes": scopes}[argv[2]]
    with tempfile.TemporaryDirectory() as where:
        return 1 if check(fixture(root, Path(where))) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
