#!/usr/bin/env python3
"""Select the check runs a release waits on (see CONTRIBUTING.md)."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

GATE_EVENTS = frozenset({"push", "pull_request"})

# A dispatch is a gate when the same workflow also gates this commit.
DISPATCH_EVENT = "workflow_dispatch"

# pr-gate's job runs on pull_request_target alone, so a push never produces
# it; a stale name here times the release out rather than skipping the rule.
PR_ONLY = frozenset({"gate"})

# GitHub's own acceptance for a required check.
ACCEPTED_CONCLUSIONS = frozenset({"success", "skipped", "neutral"})

# The app whose rows satisfy a required context; another app's row does not.
GATE_APP = "github-actions"

# The only join from a check run to the run that produced it.
RUN_ID_RE = re.compile(r"/actions/runs/(\d+)(?:/|$)")


def parse_pages(raw: str, key: str) -> list[dict]:

    decoder = json.JSONDecoder()
    merged: list[dict] = []
    index, length = 0, len(raw)
    while index < length:
        while index < length and raw[index] in " \t\r\n":
            index += 1
        if index >= length:
            break
        document, index = decoder.raw_decode(raw, index)
        if isinstance(document, dict):
            merged.extend(document.get(key) or [])
    return merged


def required_contexts(rules: object) -> set[str]:
    """The check names main requires, minus the ones a push never produces.

    A malformed document raises, never reads as empty.
    """
    if not isinstance(rules, list):
        raise ValueError("the branch rules are not an array")
    contexts: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("type") != "required_status_checks":
            continue
        parameters = rule.get("parameters") or {}
        for entry in parameters.get("required_status_checks") or []:
            context = (entry or {}).get("context")
            if not isinstance(context, str) or not context:
                raise ValueError("a required status check names no context")
            contexts.add(context)
    return contexts - PR_ONLY


def run_id_of(check_run: dict) -> str | None:

    match = RUN_ID_RE.search(str(check_run.get("html_url") or ""))
    return match.group(1) if match else None


def gate_workflow_paths(workflow_runs: list[dict], sha: str) -> set[str]:

    return {run["path"] for run in workflow_runs
            if run.get("head_sha") == sha
            and run.get("event") in GATE_EVENTS
            and run.get("path")}


def _judged(check_run: dict, runs_by_id: dict[str, dict],
            gate_paths: set[str], self_path: str | None, sha: str,
            self_run_id: str | None, self_job: str) -> tuple[bool, str]:
    run_id = run_id_of(check_run)
    if check_run.get("name") == self_job and run_id in (None, self_run_id):
        return False, "this job"
    run = runs_by_id.get(run_id) if run_id is not None else None
    if run is None:
        # An unresolvable run is not evidence that the row is noise.
        return True, ""
    # Its own workflow at any attempt: a re-cut of a commit whose earlier
    # release run failed must not refuse on that predecessor's answer.
    if self_path is not None and run.get("path") == self_path:
        return False, "this workflow's own run"
    if run.get("head_sha") != sha:
        return False, f"run {run_id} answers for another commit"
    event = run.get("event")
    if event in GATE_EVENTS or (
            event == DISPATCH_EVENT
            and (not gate_paths or run.get("path") in gate_paths)):
        return True, ""
    return False, f"run {run_id} event {event} ({run.get('path')})"


def row(check_run: dict) -> str:

    app = check_run.get("app") or {}
    return "\t".join([str(check_run.get("status") or ""),
                      str(check_run.get("conclusion") or "-"),
                      str(check_run.get("name") or ""),
                      str(app.get("slug") or "-")])


def unmet_required(rows: list[str], required: set[str]) -> list[str]:
    """Required contexts to report as still pending, sorted.

    A name with a live or failed row is left out: the caller folds it.
    """
    satisfied: set[str] = set()
    entries: dict[str, list[tuple[str, str, str]]] = {}
    for line in rows:
        status, conclusion, name, app = line.split("\t")
        entries.setdefault(name, []).append((status, conclusion, app))
        if (status == "completed" and conclusion in ACCEPTED_CONCLUSIONS
                and app == GATE_APP):
            satisfied.add(name)
    unmet: list[str] = []
    for name in sorted(set(required) - satisfied):
        reported = entries.get(name, [])
        if any(status != "completed" for status, _conclusion, _app in reported):
            continue
        if all(conclusion in ACCEPTED_CONCLUSIONS
               for _status, conclusion, _app in reported):
            unmet.append(name)
    return unmet


def select(check_runs: list[dict], workflow_runs: list[dict], sha: str,
           self_run_id: str | None, self_job: str,
           self_path: str | None = None,
           required: set[str] | None = None) -> tuple[list[str], list[str]]:
    runs_by_id = {str(run["id"]): run
                  for run in workflow_runs if run.get("id") is not None}
    gate_paths = gate_workflow_paths(workflow_runs, sha)
    # Read off the run itself: a dispatch carrying `sha=` is recorded
    # against the branch tip, so a re-cut is absent from a head-SHA listing.
    if self_path is None and self_run_id is not None:
        self_run = runs_by_id.get(str(self_run_id))
        self_path = self_run.get("path") if self_run else None
    rows: list[str] = []
    notes: list[str] = []
    for check_run in check_runs:
        judged, why = _judged(check_run, runs_by_id, gate_paths, self_path,
                              sha, self_run_id, self_job)
        if judged:
            rows.append(row(check_run))
        else:
            notes.append(f"skipping check {check_run.get('name')!r}: {why}")
    for name in unmet_required(rows, required or set()):
        rows.append(f"pending\t-\t{name}\t{GATE_APP}")
    return rows, notes


def _read(source: str) -> str:
    if source == "-":
        return sys.stdin.read()
    return Path(source).read_text(encoding="utf-8")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True,
                        help="the commit being released")
    parser.add_argument("--checks", default="-",
                        help="check-runs JSON, or - for stdin")
    parser.add_argument("--runs", default="-",
                        help="workflow-runs JSON, or - for stdin")
    parser.add_argument("--rules", default="",
                        help="branch rules JSON; without it nothing is "
                             "required and only rows are selected")
    parser.add_argument("--self-job", default="release",
                        help="this workflow's job name")
    parser.add_argument("--self-run-id", default="",
                        help="this workflow run's id, when known")
    parser.add_argument("--self-path", default="",
                        help="this workflow file's repo-relative path, when "
                             "known; falls back to the runs listing")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        required = (required_contexts(json.loads(_read(args.rules)))
                    if args.rules else set())
        checks = parse_pages(_read(args.checks), "check_runs")
        runs = parse_pages(_read(args.runs), "workflow_runs")
    except (ValueError, json.JSONDecodeError) as error:
        print(f"release_gate: cannot read the facts a release waits on: {error}",
              file=sys.stderr)
        return 2
    rows, notes = select(checks, runs, args.sha,
                         args.self_run_id or None, args.self_job,
                         args.self_path or None, required)
    for note in notes:
        print(note, file=sys.stderr)
    for line in rows:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
