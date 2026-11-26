#!/usr/bin/env python3
"""The release model: its scripts' decisions, and the workflows wired to them."""
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(relative):
    path = root / relative
    if not path.exists():
        raise SystemExit(f"{relative}: missing")
    return path.read_text(encoding="utf-8")


def exactly_one(text, needle, where):
    count = text.count(needle)
    if count != 1:
        raise SystemExit(f"{where}: expected exactly one {needle!r}, found {count}")
    return text.index(needle)


gate = load("release_gate", root / "scripts/ci/release_gate.py")
dispatch = load("release_dispatch", root / "scripts/ci/release_dispatch.py")
guard = load("version_guard", root / "scripts/ci/version_guard.py")


# What a release waits on comes from the branch rules, minus PR-only rows.
rules = [
    {"type": "deletion"},
    {"type": "required_status_checks",
     "parameters": {"required_status_checks": [
         {"context": "shellcheck"}, {"context": "actionlint"}, {"context": "gate"}]}},
]
required = gate.required_contexts(rules)
assert required == {"shellcheck", "actionlint"}, required
assert "gate" not in required
try:
    gate.required_contexts({"not": "an array"})
    raise SystemExit("release_gate: a non-array rules document was accepted")
except ValueError:
    pass
try:
    gate.required_contexts([{"type": "required_status_checks",
                             "parameters": {"required_status_checks": [{}]}}])
    raise SystemExit("release_gate: a contextless required check was accepted")
except ValueError:
    pass


# Which rows a release judges: the producing run decides, not the name.
SHA = "a" * 40
OTHER = "b" * 40


def check(name, status, conclusion, url, app="github-actions"):
    return {"name": name, "status": status, "conclusion": conclusion,
            "html_url": url, "app": {"slug": app}}


def run(number, event, path, sha=SHA):
    return {"id": number, "event": event, "path": path, "head_sha": sha}


# A /claim publishes a claim row on the default branch tip, and an
# issue_comment run vouches for nothing here; actions/check-runs says so.
runs = [
    run(1, "push", ".github/workflows/tests.yml"),
    run(2, "pull_request", ".github/workflows/tests.yml"),
    run(3, "issue_comment", ".github/workflows/claim.yml"),
    run(4, "push", ".github/workflows/release.yml"),
    run(5, "push", ".github/workflows/actionlint.yml", sha=OTHER),
    run(6, "pull_request_target", ".github/workflows/pr-gate.yml"),
]
checks = [
    check("shellcheck", "completed", "success", "https://x/actions/runs/1/job/1"),
    check("actionlint", "in_progress", None, "https://x/actions/runs/2/job/2"),
    check("claim", "completed", "failure", "https://x/actions/runs/3/job/3"),
    check("release", "completed", "failure", "https://x/actions/runs/4/job/4"),
    check("suites (ubuntu-latest)", "completed", "failure",
          "https://x/actions/runs/5/job/5"),
    check("plan", "completed", "failure", "https://x/actions/runs/6/job/6"),
    check("comment-share", "completed", "success",
          "https://x/actions/runs/2/job/7", app="other-app"),
]
rows, notes = gate.select(checks, runs, SHA, "4", "release",
                          ".github/workflows/release.yml",
                          {"shellcheck", "actionlint", "comment-share",
                           "size-baseline"})
names = [line.split("\t")[2] for line in rows]
assert names == ["shellcheck", "actionlint", "comment-share",
                 "comment-share", "size-baseline"], names
assert any("this job" in note for note in notes), notes
assert any("issue_comment" in note for note in notes), notes
assert rows[1].split("\t")[0] == "in_progress"
assert [line.split("\t")[0] for line in rows[3:]] == ["pending", "pending"]

assert gate.unmet_required(
    ["completed\tfailure\tshellcheck\tgithub-actions"], {"shellcheck"}) == []
assert gate.unmet_required([], {"size-baseline"})
assert not gate.unmet_required(
    ["completed\tsuccess\tshellcheck\tgithub-actions"], {"shellcheck"})


# A dispatch run is recorded against the branch tip, so it is absent from a
# listing filtered by head SHA: with no path handed in, this workflow's own
# run is resolved from the listing by run id, and every row it produced is
# dropped by its path. A row whose run cannot be read is judged, not shed.
nothing, _ = gate.select([check("release (verify)", "completed", "failure",
                                "https://x/actions/runs/4/job/4")],
                         runs, SHA, "4", "release", None, set())
assert nothing == [], nothing
unread, _ = gate.select([check("release", "completed", "failure",
                               "https://x/actions/runs/9/job/9")],
                        runs, SHA, "4", "release", None, set())
assert [line.split("\t")[2] for line in unread] == ["release"], unread

# A dispatch row is judged when the same workflow also gates this commit,
# and skipped when it does not.
dispatch_runs = [run(7, "workflow_dispatch", ".github/workflows/tests.yml"),
                 run(8, "workflow_dispatch", ".github/workflows/scorecard.yml"),
                 run(1, "push", ".github/workflows/tests.yml")]
rows, _ = gate.select(
    [check("dispatch gate", "completed", "success", "https://x/actions/runs/7/job/1"),
     check("other dispatch", "completed", "failure", "https://x/actions/runs/8/job/1")],
    dispatch_runs, SHA, None, "release", None, set())
assert [line.split("\t")[2] for line in rows] == ["dispatch gate"], rows

# Dispatch decisions and the successor main is raised to.
assert dispatch.decide("3.1.0", False, False).ok
assert not dispatch.decide("3.1.0", True, False).ok
assert not dispatch.decide("3.1.0", False, True).ok
assert not dispatch.decide("3.1", False, False).ok
assert not dispatch.decide("v3.1.0", False, False).ok
out = io.StringIO()
with contextlib.redirect_stdout(out):
    assert dispatch.main(["successor", "3.1.0"]) == 0
assert out.getvalue() == "3.1.1-dev\n", out.getvalue()


# The tree version must name nothing published.
assert guard.decide("3.1.0-dev", False).ok
assert not guard.decide("3.1.0-dev", True).ok
assert not guard.decide("3.1.0", True).ok
assert guard.decide("3.1.0", False).ok
assert not guard.decide("v3.1.0-dev", False).ok
assert not dispatch.decide("3.1.0-dev", False, False).ok


# The wiring: who triggers a release, what it waits on, what is pushed.
version = read("VERSION").strip()
assert version.endswith("-dev"), (
    f"VERSION is {version!r}: merging must cut no release until it loses -dev")
assert guard.decide(version, False).ok

release = read(".github/workflows/release.yml")
for line in ("workflows: [tests]", "contents: write", "checks: read",
             "actions: read", "queue: max",
             "github.event.workflow_run.event == 'push'",
             "github.event.workflow_run.head_branch == 'main'",
             "github.event.workflow_run.conclusion == 'success'",
             "if [ \"$CLAIM_REF\" != 'refs/heads/main' ]",
             "--rules \"$RUNNER_TEMP/rules.json\"",
             "scripts/ci/release_gate.py?ref=$CLAIM_SELECTOR_SHA",
             ".github/scripts/retry.sh?ref=$CLAIM_SELECTOR_SHA",
             "prerelease=${version#*-}",
             "if echo \"$version\" | grep -q -- '-'",
             "not at $CLAIM_SHA — failing closed",
             "$2 != \"success\" && $2 != \"skipped\" && $2 != \"neutral\"",
             "grep -cv '^completed'",
             'gh release create "$CLAIM_TAG"', '--target "$CLAIM_SHA"',
             "--jq .target_commitish"):
    exactly_one(release, line, "release.yml")
assert release.count("releases/tags/$CLAIM_TAG") == 2
assert release.count("HTTP 404") == 3

dispatched = read(".github/workflows/release-dispatch.yml")
for job in ("validate", "bump", "decide", "successor"):
    exactly_one(dispatched, f"\n  {job}:\n", "release-dispatch.yml")
for line in ("workflows: [release]",
             "chore(version): Release $CLAIM_VERSION",
             "chore(version): Raise VERSION to $CLAIM_SUCCESSOR",
             "needs.decide.result == 'success'",
             "VERSION?ref=refs/heads/main",
             "commits?path=VERSION&per_page=30",
             "Another commit introduced main's VERSION",
             "expected released",
             "the release run concluded $CLAIM_RELEASE_CONCLUSION",
             "if [ \"$CLAIM_RELEASE_CONCLUSION\" != 'success' ]; then",
             "if [ \"$CLAIM_SHA\" != \"$introducer\" ]; then"):
    exactly_one(dispatched, line, "release-dispatch.yml")
assert dispatched.count("did not happen") == 2
assert dispatched.count("environment: main-push") == 2

tests = read(".github/workflows/tests.yml")
for line in ("scripts/ci/version_guard.py decide", 'core="${version%%-*}"',
             'git/ref/tags/v$core', "HTTP 404",
             "could not verify the tag probe for v$core — failing closed"):
    exactly_one(tests, line, "tests.yml")

# One scan definition, and no workflow carries a copy of it.
for workflow_name in ("tests.yml", "secrets.yml"):
    exactly_one(read(f".github/workflows/{workflow_name}"),
                "run: .github/scripts/secrets-scan.sh", workflow_name)
for workflow in sorted((root / ".github/workflows").glob("*.yml")):
    assert "gitleaks detect" not in workflow.read_text(), (
        f"{workflow.name} runs gitleaks itself instead of the shared scan")

scan = read(".github/scripts/secrets-scan.sh")
assert "sha256sum -c -" in scan
# Run the scan with a stand-in binary: what it is handed comes from the base
# branch, whatever the judged tree carries.
with tempfile.TemporaryDirectory() as scratch:
    box, env = Path(scratch), {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull}
    env["PATH"] = f"{box / 'bin'}{os.pathsep}{env['PATH']}"
    env.update(TAR_GIVES=str(box / "gitleaks"), SEEN=str(box / "seen"))

    def git(*args):
        subprocess.run(("git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                        "-C", str(box / "tree")) + args, check=True, capture_output=True, env=env)
    for folder in ("bin", "seen", "tree/.github/scripts"):
        (box / folder).mkdir(parents=True)
    stand_ins = {"bin/sha256sum": "cat > /dev/null", "bin/tar": 'cp "$TAR_GIVES" "$4/gitleaks"',
                 "tree/.github/scripts/download.sh": ': > "$2"',
                 "gitleaks": 'printf "%s\\n" "$@" > "$SEEN/argv"; cp "$6" "$SEEN/config"; '
                             'cp -r "$8" "$SEEN/ignore"; ls -A > "$SEEN/tree"; '
                             'cp "$(git rev-parse --git-path info/attributes)" "$SEEN/attributes"'}
    for stand_in, body in stand_ins.items():
        (box / stand_in).write_text(f"#!/bin/sh\n{body}\n")
        (box / stand_in).chmod(0o755)
    for helper in ("secrets-scan.sh", "retry.sh"):
        shutil.copy(root / ".github/scripts" / helper, box / "tree/.github/scripts")
    subprocess.run(("git", "init", "-q", "--bare", str(box / "origin.git")), check=True)
    subprocess.run(("git", "init", "-q", "-b", "main", str(box / "tree")), check=True)
    git("remote", "add", "origin", (box / "origin.git").as_uri())
    for stage, extra, attributes in (("base", "# base\n", ""),
                                     ("head", 'disabledRules = ["x"]\n', "* -diff\n")):
        (box / "tree/.gitleaks.toml").write_text("[extend]\nuseDefault = true\n" + extra)
        (box / "tree/.gitleaksignore").write_text(f"{stage}-ignore\n")
        (box / "tree/.gitattributes").write_text(attributes)
        git("add", "-A", "-f")
        git("commit", "-qm", stage)
        if stage == "base":
            git("push", "-q", "origin", "main")
    done = subprocess.run([".github/scripts/secrets-scan.sh"], cwd=box / "tree", env=env,
                          capture_output=True, text=True, check=False)
    assert done.returncode == 0, done.stderr
    seen = {part: (box / "seen" / part).read_text()
            for part in ("argv", "config", "tree", "attributes")}
    assert seen["config"].endswith("# base\n") and seen["attributes"] == "* diff\n", seen
    assert (box / "seen/ignore/.gitleaksignore").read_text() == "base-ignore\n"
    assert ".gitleaksignore" not in seen["tree"].split(), seen["tree"]
    for flag in ("--ignore-gitleaks-allow", "--redact",
                 "--log-opts=--all --full-history --diff-filter=uxdb --diff-merges=remerge"):
        assert flag in seen["argv"].splitlines(), (flag, seen["argv"])
config = read(".gitleaks.toml")
assert "useDefault = true" in config
sections = [line for line in config.splitlines() if line.startswith("[")]
assert sections == ["[extend]"], (
    f".gitleaks.toml adds a section beside [extend]: {sections}")

print("release model: decisions and wiring pinned")
