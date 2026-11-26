#!/usr/bin/env python3
"""The release model: its scripts' decisions, and the workflows wired to them."""
import contextlib
import importlib.util
import io
import sys
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


# The wiring: who triggers a release, what it waits on, what is pushed.
version = read("VERSION").strip()
assert version.endswith("-dev"), (
    f"VERSION is {version!r}: merging must cut no release until it loses -dev")
assert guard.decide(version, False).ok

release = read(".github/workflows/release.yml")
exactly_one(release, "workflows: [tests]", "release.yml")
exactly_one(release, "contents: write", "release.yml")
exactly_one(release, "--rules \"$RUNNER_TEMP/rules.json\"", "release.yml")
exactly_one(release, "scripts/ci/release_gate.py?ref=$CLAIM_SELECTOR_SHA",
            "release.yml")
exactly_one(release, 'gh release create "$CLAIM_TAG"', "release.yml")
assert "\n      checks: read" in release
assert "\n      actions: read" in release

dispatched = read(".github/workflows/release-dispatch.yml")
for job in ("validate", "bump", "decide", "successor"):
    exactly_one(dispatched, f"\n  {job}:\n", "release-dispatch.yml")
exactly_one(dispatched, "workflows: [release]", "release-dispatch.yml")
exactly_one(dispatched, "chore(version): Release $CLAIM_VERSION",
            "release-dispatch.yml")
exactly_one(dispatched, "chore(version): Raise VERSION to $CLAIM_SUCCESSOR",
            "release-dispatch.yml")
assert dispatched.count("environment: main-push") == 2
assert "refs/heads/main" in dispatched

tests = read(".github/workflows/tests.yml")
exactly_one(tests, "scripts/ci/version_guard.py decide", "tests.yml")

# One scan definition, and no workflow carries a copy of it.
for workflow_name in ("tests.yml", "secrets.yml"):
    exactly_one(read(f".github/workflows/{workflow_name}"),
                "run: .github/scripts/secrets-scan.sh", workflow_name)
for workflow in sorted((root / ".github/workflows").glob("*.yml")):
    assert "gitleaks detect" not in workflow.read_text(), (
        f"{workflow.name} runs gitleaks itself instead of the shared scan")

scan = read(".github/scripts/secrets-scan.sh")
assert "--ignore-gitleaks-allow" in scan
config = read(".gitleaks.toml")
assert "useDefault = true" in config
sections = [line for line in config.splitlines() if line.startswith("[")]
assert sections == ["[extend]"], (
    f".gitleaks.toml adds a section beside [extend]: {sections}")

print("release model: decisions and wiring pinned")
