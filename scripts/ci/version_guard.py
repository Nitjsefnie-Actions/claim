#!/usr/bin/env python3
"""Refuse a tree VERSION that names an already-published release."""
from __future__ import annotations

import argparse
import sys
import re
from typing import NamedTuple

# The core has no hyphen, so the first `-` starts the suffix.
_VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.-]+))?$")


class Decision(NamedTuple):
    ok: bool
    reason: str


def parse_version(text: str) -> tuple[str, str]:
    """Split a version into `(core, prerelease)`; anything else raises."""
    match = _VERSION_RE.match(text)
    if match is None:
        raise ValueError(
            f"not a version (X.Y.Z with optional -suffix): {text!r}"
        )
    return match.group(1), match.group(2) or ""


def decide(version: str, tag_exists: bool) -> Decision:
    try:
        core, _prerelease = parse_version(version)
    except ValueError:
        return Decision(
            False,
            f"version {version!r} is not semver "
            "(expected X.Y.Z with an optional -suffix)",
        )
    if tag_exists:
        return Decision(
            False,
            f"v{core} is already published — this tree must not carry that "
            "version again; raise VERSION (e.g. to the next -dev) instead",
        )
    return Decision(True, f"v{core} is not an existing tag — nothing published names it")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    decide_p = sub.add_parser(
        "decide", help="decide whether a tree version may pass"
    )
    decide_p.add_argument("--version", required=True,
                          help="tree VERSION, e.g. 3.1.0-dev")
    decide_p.add_argument("--tag-exists", required=True,
                          choices=["true", "false"],
                          help="whether tag v<core> exists")
    args = parser.parse_args(argv)
    decision = decide(args.version, args.tag_exists == "true")
    print(decision.reason)
    return 0 if decision.ok else 1


if __name__ == "__main__":
    sys.exit(main())
