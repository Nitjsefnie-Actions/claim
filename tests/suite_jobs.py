"""tests/suite_legs.py's python-versions and diff-coverage checks, and `Refused`."""

import re
from typing import NoReturn


class Refused(Exception):
    """A file carries a shape this pin does not model."""


def refuse(line, reason) -> NoReturn:
    raise Refused(f"{reason}: {line!r}")


def python_list_header(line):
    """The versions column header a python-versions `python:` line implies."""
    value = line.strip()[len("python:"):].strip()
    if not re.fullmatch(r'\["\d+\.\d+"(?:, "\d+\.\d+")*\]', value):
        refuse(line, "the python-versions `python:` list is not the "
                     "one-line list of double-quoted X.Y versions this "
                     "pin reads")
    versions = [tuple(int(part) for part in item.split("."))
                for item in re.findall(r'"([^"]+)"', value)]
    for earlier, later in zip(versions, versions[1:]):
        if later != (earlier[0], earlier[1] + 1):
            refuse(line, "the python-versions `python:` list does not "
                         "ascend by one minor version, so no range "
                         "header can name it")
    first, last = versions[0], versions[-1]
    return f"{first[0]}.{first[1]}–{last[0]}.{last[1]} (ubuntu)"


def diff_coverage_step_list(steps):
    """The diff-coverage job's steps, pinned to the landed seven."""
    if len(steps) != 7:
        refuse(f"[{len(steps)} steps]",
               "expected exactly seven steps in the diff-coverage job")
    # Prefix only: the pin and its `with:` inputs are not this pin's.
    for step, prefix, where in ((steps[0], "actions/checkout@", "first"),
                                (steps[2], "actions/setup-python@", "third")):
        if not (step["uses"] or "").startswith(prefix):
            refuse("[step dash]",
                   f"expected a dash-`uses:` {prefix} step as the "
                   f"diff-coverage job's {where} step")
        if step["name"] is not None or step["if"] is not None:
            refuse("[step]", f"the diff-coverage step carrying `{prefix}` "
                             "carries a name or condition this pin does not "
                             "model")
    for step, name in zip(steps[1:2] + steps[3:], (
            "Download the coverage XML",
            "Install coverage tooling",
            "Measure the coverage of this change",
            "Package the comment for the trusted commenter",
            "Upload the comment for the trusted commenter")):
        if step["name"] != name:
            refuse("[named step]",
                   f"expected the diff-coverage step `{name}` at its "
                   "landed position")
        if step["if"] is not None:
            refuse(step["if"], "a diff-coverage step carrying an `if:` -- "
                               "the job-level condition gates the whole "
                               "job, so a step condition is a shape this "
                               "pin does not model")
