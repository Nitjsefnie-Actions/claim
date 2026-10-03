#!/usr/bin/env python3
"""The suite-legs pin, over .github/workflows/tests.yml and README.md.

Issue #141: tests.yml scopes every per-leg step with an `if:` and README.md
answers, per leg, in its "Runners and Python versions" coverage table. Nothing
held the two together, so a step re-scoped in the workflow, a table cell
edited, or a row moved landed green while the README promised legs CI does not
run -- or hid legs CI does. This guard reads the matrix and every scoped step
from the workflow, the table cells from the README, and fails the ordinary way
(exit 1, naming the row and the legs) when the two disagree.

Like tests/codeql_matrix.py, it is a guard that reads only the lines its pin
depends on and refuses rather than parses; no package installs (CONTRIBUTING's
promise), so no YAML or Markdown library stands behind it. The lines read, and
the only lines read:

  - from tests.yml: the `jobs:` anchor; exactly the `shellcheck:`,
    `suites:` and `python-versions:` job keys under it; inside `suites:` the
    `strategy:` / `matrix:` / `os:` / `include:` / `steps:` anchor chain at
    exactly their indents, in that order, each exactly once; the matrix
    `os:` one-line flow list and the `include:` entries; every step under
    `steps:` of the `suites` and `python-versions` jobs, read for its
    `name:` / `if:` / `id:` at the step key indent (a dash line may carry
    `uses:` or `name:`; a dash-carried value is read with any `# v7.0.1`-
    style SHA comment truncated, because the value's identity is the SHA,
    and the python-versions dashes are additionally prefix-checked); and the
    `runs-on:` line that consumes `matrix.os`;
  - from README.md: the one `| Check |` table header, its `---` separator,
    and the run of `|`-led data rows that follows, and nothing else.

The admitted VALUE shape is a plain scalar only -- no quotes on `if:` values
(the landed spellings are read whole, and a different spelling refuses rather
than re-parse), no tag, anchor, alias, merge key, flow collection on a scalar,
no trailing comment. The `os:` list is the one flow shape read, and only in
the landed one-line `[a, b]` spelling. Two closures take the place of
codeql_matrix.py's file-wide block-scalar arm, which tests.yml cannot carry
because healthy steps write their bodies as `run: |` block scalars. First,
every line the pin reads as a key or value gets its refusal at the point of
reading: a valued `jobs:`/job/`strategy:`/`steps:` anchor refuses in
bare(), an entry or dash keyed other than `os:`/`name:`/`uses:` refuses in
its grammar, and any value read through plain() refuses a `|`/`>` value --
so no block-scalar KEY survives into the reading. Second, the indent
arithmetic bounds what a surviving scalar body can host: a block scalar's
body sits strictly deeper than its key, so a body can never present an
indent-8 `name:`/`if:`/`id:` line (the deepest keys the pin reads, under
indent-6 dashes), and the include-entry window closes at the first line
dedenting below the entry column -- the `runs-on:` line -- so nothing
beyond it is read as an entry. The
file-wide TAB arm is kept: a tab-led line is refused rather than read at the
wrong column, and YAML forbids it outright. A README table read by line
shape carries no indentation model, so the tab arm does not apply to it; a
fenced copy of a table inside README prose would be read as a table of its
own, so a second `| Check |` header refuses rather than let the pin choose
between two tables.

Legs, and how they are derived:

  - the matrix legs come from the `os:` list plus the `include:` entries,
    each value mapped by the pinned LEG_FOR_OS table to its README column
    (`ubuntu-latest` -> `ubuntu`, and so on); an `os` value outside that
    table refuses, because a leg with no README column is exactly the drift
    this guard exists to name;
  - a step's leg set comes from its `if:` by operator semantics, and exactly
    these landed spellings are modelled -- every other spelling refuses:

      no `if:` line     -> the matrix legs (the step runs on every leg the
                           matrix declares, so a leg dropped from the matrix
                           shrinks the step, and its row reds);
      `runner.os == 'Windows'`  -> {windows};
      `matrix.os != 'windows-latest'` -> the live matrix legs minus windows;
      `matrix.os == 'ubuntu-latest'`  -> the live matrix legs that are ubuntu;
      -- the last two derive rather than name constants, because the pin's
      purpose is agreement surviving a changed matrix: constants would
      false-red a consistent README update after a matrix edit and let the
      drift through once the guard's own two messages had been remediated
      row by row;
      `${{ !cancelled() && steps.install_checks.outcome == 'success' }}`
          -> the legs of the step carrying `id: install_checks`, resolved
          one level deep: the status functions suppress GitHub's implicit
          success(), so the chain's real reach is wherever that step ran
          and succeeded -- its leg set, not its own text's. The indirection
          is modelled deliberately (the alternative was refusing every
          chained step outright); a chain step whose id-step is missing,
          duplicated, or itself chained refuses. An absent `if:` and an
          empty one are distinguished: an `if:` with no value refuses,
          because GitHub reads it as never-true while an absent one runs
          unconditionally.

  - the python-versions job's step list is pinned to exactly the checkout
    dash-`uses:` step, the setup-python dash-`uses:` step, and one named
    `Run the behavioral suite` step carrying no `if:`; any other step, name
    or condition there refuses. Its behavioral-suite step is what the
    README's `3.11-3.14 (ubuntu)` column means: a row claims that column
    when one of its steps is that step.

Comparison: every table row is mapped by the pinned ROW_STEPS table to the
workflow step or steps that implement it; a multi-step row derives the
INTERSECTION of its steps' leg sets, because the row promises the whole
check; and the versions column is derived when one of the row's steps is the
python-versions behavioral-suite step. Both directions are defects: a cell
claiming a leg the workflow does not grant, and a step running a leg the
cell denies -- each red names its own direction. A table row the mapping
does not model refuses (exit 3): a renamed or added row is an edit to this
pin, not a row to skip. A mapping key whose row vanished from the README,
and a mapped step that no longer exists in the workflow, fail semantically
(exit 1), naming the drifted half. Every step carrying an `if:` must be
mapped by some row or named in EXEMPT_STEPS; the two checkout steps carry
no `if:` and sit outside the sweep.

Shapes this pin refuses on a fine file, stated rather than assumed (the
false-positive audit): a tab-led line anywhere in the workflow; a fourth job
key under `jobs:`; a quoted or multi-line `os:` flow list, or an `os` value
with no README column; an `include:` entry keyed other than `os:`; a
near-miss `if:` such as `matrix.os == 'windows-latest'` or a double-quoted
operand; an empty-valued `if:`; a `with:` block under a step is unread, not
admitted. In the README: a missing, duplicated or renamed header; a
malformed separator; a ragged row; a cell outside the yes/no grammar; an
unknown row label; a duplicate row label.
"""

from pathlib import Path
import re
import sys
from typing import NoReturn

WORKFLOW = ".github/workflows/tests.yml"
README = "README.md"

# Indentation of every read line, fixed by the file's layout. A layout edit
# is a deliberate edit to this pin.
JOBS, JOB, JOB_KEY = 0, 2, 4
MATRIX, MATRIX_KEY, ENTRY = 6, 8, 10
STEP, STEP_KEY = 6, 8

# A value starting with any of these is not a plain scalar this pin reads
# (same set as codeql_matrix.py; the `os:` flow list is read before this set
# is consulted, so its brackets never reach here as a scalar).
INDICATORS = "|>{[&*!'\"?"

# README column key for each matrix `os` value, and the README header spelling
# each column answers to. A matrix value outside LEG_FOR_OS is a leg no
# README column can answer, so it refuses instead of comparing.
LEG_FOR_OS = {
    "ubuntu-latest": "ubuntu",
    "macos-latest": "macos",
    "windows-latest": "windows",
}
COLUMNS = ("ubuntu", "macos", "windows", "versions")
HEADER = ("ubuntu", "macos", "windows", "3.11–3.14 (ubuntu)")

# The four landed `if:` spellings, matched against the normalised value.
WINDOWS_IF = "runner.os == 'Windows'"
NOT_WINDOWS_IF = "matrix.os != 'windows-latest'"
UBUNTU_IF = "matrix.os == 'ubuntu-latest'"
CHAIN_IF = "${{ !cancelled() && steps.install_checks.outcome == 'success' }}"
CHAIN_ID = "install_checks"

# README Check label -> the workflow steps that implement the check. A row
# the README renames refuses on the read side; a step renamed in the
# workflow fails here on the semantic side.
ROW_STEPS = {
    "Behavioral suite": ("Run the behavioral suite",),
    "ruff lint of claim.py": ("Lint the claim script",),
    "pycodestyle, pylint and pyright": ("pycodestyle", "pylint", "pyright"),
    "Coverage measurement and gate": (
        "Install coverage tooling", "Record the coverage summary",
        "Coverage gate"),
    "Merge-conflict marker check": (
        "Check no tracked file carries a merge-conflict marker",),
    "Compile the claim script": ("Compile the claim script",),
    "Put a python3 on PATH": ("Put a python3 on PATH",),
}

# Steps the table deliberately does not document. The toolchain install is
# not a check a reader runs; its reach is carried by the chain spelling that
# reads `steps.install_checks.outcome`, so a re-scope of this step shrinks
# the chained steps' derived legs and reds their row through the chain.
EXEMPT_STEPS = ("Install the type and lint toolchain",)


class Refused(Exception):
    """A file carries a shape this pin does not model."""


def refuse(line, reason) -> NoReturn:
    raise Refused(f"{reason}: {line!r}")


def normalise(value):
    return re.sub(r"\$\{\{.*?\}\}",
                  lambda m: "${{ " + m[0][3:-2].strip() + " }}", value)


def structural(lines):
    """The (index, indent, text) of every non-blank, non-comment line."""
    kept = []
    for index, line in enumerate(lines):
        if line.strip() and not line.lstrip().startswith("#"):
            lead = line[:len(line) - len(line.lstrip())]
            if "\t" in lead:
                refuse(line, "a tab in a line's indentation, which YAML forbids")
            kept.append((index, len(line) - len(line.lstrip(" ")), line))
    return kept


def plain(line, value, key):
    """The value as a plain scalar, refusing every other spelling."""
    value = value.strip()
    if value[:1] in INDICATORS:
        refuse(line, f"`{key}` carries a value this pin does not model")
    if ": " in value:
        refuse(line, f"`{key}` carries two mappings on one line")
    if " #" in value:
        refuse(line, f"`{key}` carries a trailing comment this pin does not read")
    return normalise(value)


def flow_list(line, value, key):
    """The one flow shape the pin reads: a one-line `[a, b]` of plain items.

    The matrix `os:` list is data the pin needs, and its landed spelling is
    a flow sequence, so it is read here and nowhere else. Multi-line flow,
    quoted items and empty items all refuse: each is a spelling a
    maintainer adopts as a deliberate edit to this pin.
    """
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        refuse(line, f"`{key}` is not the one-line flow list this pin reads")
    read = []
    for item in value[1:-1].split(","):
        if not item.strip():
            refuse(line, f"`{key}` carries an empty flow item")
        read.append(plain(line, item, f"{key} item"))
    return read


def at_indent(lines, indent, pattern):
    """The lines matching `pattern` at exactly `indent`."""
    return [entry for entry in lines
            if entry[1] == indent and re.fullmatch(pattern, entry[2].strip())]


def exactly_one(lines, indent, pattern, what):
    """The one line matching `pattern` at exactly `indent`; refuse unless
    there is exactly one. Zero is a missing region; more than one is an
    ambiguity no reading survives."""
    found = at_indent(lines, indent, pattern)
    if len(found) != 1:
        refuse(f"[{len(found)} matching lines]",
               f"expected exactly one {what} at indent {indent}")
    return found[0]


def bare(lines, indent, key, where):
    """The one line that is exactly `key` at exactly `indent`."""
    found = [entry for entry in lines
             if entry[1] == indent
             and re.fullmatch(re.escape(key) + r".*", entry[2].strip())]
    if len(found) != 1:
        refuse(f"[{len(found)} matching lines]",
               f"expected exactly one bare `{key}` line at indent {indent} "
               f"in {where}")
    entry = found[0]
    if entry[2].strip() != key:
        refuse(entry[2], f"`{key}` must be a bare key, not carry a value")
    return entry


def between(lines, start, stop=None):
    """The entries strictly after `start` and strictly before `stop`'s index."""
    return [entry for entry in lines
            if entry[0] > start[0] and (stop is None or entry[0] < stop[0])]


def job_span(lines, anchor):
    """The lines from just after a job key to the next indent-2 line.

    The span is bounded by the job's own key column: a job body's deeper
    lines stay inside and the next job's key ends the span. Within the
    post-`jobs:` region this walk reads, nothing else sits at indent 2
    ending in a colon, so a stray indent-2 key in a job body there would be
    picked up as a job anchor and refused by the closed job-set check that
    consumes these spans. (The `on:` block's `push:`/`pull_request:`/
    `workflow_dispatch:` keys sit at indent 2 too, and are not picked up:
    this walk starts after the `jobs:` anchor, so they are never read.)
    """
    tail = [entry for entry in lines if entry[0] > anchor[0]]
    for entry in tail:
        if entry[1] == JOB:
            return between(lines, anchor, entry)
    return between(lines, anchor)


def dash_spans(region, what):
    """The step spans of a `steps:` block: dash to next dash or region end.

    Every line in the region belongs to some step's span -- a line under
    `steps:` that no dash claims is a shape the pin does not model and is
    refused here, so a step cannot hide outside every span. A body line at
    an indent strictly between the dash and the step-key column refuses too.
    """
    dashes = [entry for entry in region
              if entry[1] == STEP and entry[2].strip().startswith("- ")]
    if not dashes:
        refuse("[0 steps]", f"expected at least one step under {what}")
    spans = []
    for number, dash in enumerate(dashes):
        stop = dashes[number + 1][0] if number + 1 < len(dashes) else None
        body = [entry for entry in region
                if entry[0] > dash[0] and (stop is None or entry[0] < stop)]
        # Any body line left of the step-key column -- a dedent that would
        # close the step in YAML -- is a layout this pin does not model.
        stray = [entry for entry in body if entry[1] < STEP_KEY]
        if stray:
            refuse(stray[0][2], "a line under a step at an indent this pin "
                                "does not model")
        spans.append((dash, body))
    return spans


def step_field(span, key):
    """The one `<key>: <plain>` line in a step span, or None when absent."""
    found = at_indent(span, STEP_KEY, re.escape(key) + r": (\S.*)")
    if len(found) > 1:
        refuse(f"[{len(found)} matching lines]",
               f"expected at most one `{key}:` in a step")
    if not found:
        return None
    return plain(found[0][2], found[0][2].strip()[len(key) + 1:], key)


def step_bare(span, key):
    """Whether the step span carries a bare `<key>:` line (no value)."""
    return bool([entry for entry in span
                 if entry[1] == STEP_KEY and entry[2].strip() == key])


def read_steps(job, job_name):
    """The steps of one job: {name, if, id} per step, `name` from the dash
    or its own line."""
    steps_anchor = bare(job, JOB_KEY, "steps:", job_name)
    region = between(job, steps_anchor)
    steps = []
    for dash, span in dash_spans(region, f"the {job_name} job's steps:"):
        dash_text = dash[2].strip()[2:]
        name = uses = None
        if dash_text.startswith("uses:"):
            # A checkout dash carries the tree's `# v7.0.1` SHA comment; the
            # value's identity is the SHA, so the comment truncates here and
            # only the action prefix is ever read.
            uses = plain(dash[2],
                         dash_text[len("uses:"):].split(" #")[0], "uses")
        elif dash_text.startswith("name:"):
            name = plain(dash[2],
                         dash_text[len("name:"):].split(" #")[0], "name")
        elif dash_text.strip():
            refuse(dash[2], "a step dash carrying a key other than `name` "
                            "or `uses`")
        if step_bare(span, "if:"):
            refuse(dash[2], "the step carries an `if:` with no value, which "
                            "GitHub reads as never-true -- refused rather "
                            "than confused with an absent `if:`")
        read_name = name if name is not None else step_field(span, "name")
        if name is not None and step_field(span, "name") is not None:
            refuse(dash[2], "a step carrying `name:` both on its dash and in "
                            "its body")
        if step_field(span, "if") is not None and read_name is None:
            refuse(dash[2], "a conditioned step with no `name:` -- the sweep "
                            "would have nothing to name it by")
        steps.append({
            "name": read_name,
            "if": step_field(span, "if"),
            "id": step_field(span, "id"),
            "uses": uses,
        })
    return steps


def legs_for_if(step, matrix_legs, legs_by_id):
    """A step's leg set from its `if:` value, by operator semantics.

    The spellings are resolved against the LIVE matrix legs, not against
    constants: the pin's purpose is README-vs-workflow agreement surviving a
    changed matrix, so `!= 'windows-latest'` means every leg the matrix
    declares except windows, and `== 'ubuntu-latest'` means the ubuntu leg
    when the matrix declares one. Constants here would false-red a fully
    consistent README update after a matrix edit and -- worse -- would let
    the drift this guard exists to name through once its own two messages
    had been remediated row by row.

    The chain spelling is resolved to the id-step's legs: `!cancelled()`
    suppresses GitHub's implicit success() gate, so the chain's real
    condition is the id-step's outcome, and its real reach is the id-step's
    -- wherever that step ran and succeeded. One level of indirection is
    modelled; a chain resolved through another chain refuses upstream.
    """
    if step["if"] is None:
        return frozenset(matrix_legs)
    condition = normalise(step["if"])
    if condition == WINDOWS_IF:
        return frozenset({"windows"})
    if condition == NOT_WINDOWS_IF:
        return frozenset(matrix_legs) - {"windows"}
    if condition == UBUNTU_IF:
        return frozenset(matrix_legs) & {"ubuntu"}
    if condition == CHAIN_IF:
        # The spelling itself names `steps.install_checks.outcome`, and
        # suites_legs() has already refused unless exactly one step carries
        # that id and is not itself chained, so the legs resolve or the
        # refusal has already fired.
        return legs_by_id[CHAIN_ID]
    refuse(step["if"], "a step `if:` this pin does not model")


def suites_legs(job):
    """The suites job: matrix legs, steps, and each step's derived legs."""
    strategy = bare(job, JOB_KEY, "strategy:", "suites")
    body = between(job, strategy)
    matrix = bare(body, MATRIX, "matrix:", "suites")
    os_line = exactly_one(between(body, matrix), MATRIX_KEY, r"os: (\S.*)",
                          "`os:` under the suites matrix")
    include = bare(body, MATRIX_KEY, "include:", "the suites matrix")
    if include[0] < os_line[0]:
        refuse(include[2], "the `include:` block must follow the `os:` list "
                           "it extends")
    os_values = flow_list(os_line[2], os_line[2].strip()[len("os:"):], "os")
    # The include block closes at the first line dedenting below the entry
    # column -- here `runs-on:` sits between it and `steps:`, so the window
    # is the entries' own column, not the anchor-to-anchor span.
    for entry in between(body, include):
        if entry[1] < ENTRY:
            break
        text = entry[2].strip()
        if not text.startswith("- "):
            refuse(entry[2], "a line inside the include block that is not "
                             "an entry")
        pair = re.fullmatch(r"os: (\S.*)", text[2:])
        if not pair:
            refuse(entry[2], "a matrix entry line this pin does not model")
        os_values.append(plain(entry[2], pair[1], "os"))
    legs = set()
    for value in os_values:
        if value not in LEG_FOR_OS:
            refuse(value, "a matrix `os` value this pin does not model, "
                          "with no README column to answer it")
        legs.add(LEG_FOR_OS[value])

    runs_on = exactly_one(job, JOB_KEY, r"runs-on: (\S.*)",
                          "`runs-on:` in the suites job")
    if plain(runs_on[2], runs_on[2].strip()[len("runs-on:"):],
             "runs-on") != "${{ matrix.os }}":
        raise AssertionError(
            f"the suites job runs on "
            f"{runs_on[2].strip()[len('runs-on:'):].strip()!r}, not "
            "'${{ matrix.os }}': the matrix os list would name legs no run "
            "ever selects")

    steps = read_steps(job, "suites")
    ids = [step["id"] for step in steps if step["id"] is not None]
    if ids.count(CHAIN_ID) != 1:
        refuse(f"[{ids.count(CHAIN_ID)} matching steps]",
               f"expected exactly one step carrying `id: {CHAIN_ID}`")
    id_step = next(step for step in steps if step["id"] == CHAIN_ID)
    if normalise(id_step["if"] or "") == CHAIN_IF:
        refuse(id_step["if"], f"the `{CHAIN_ID}` step itself chains on its "
                              "own outcome")
    legs_by_id = {CHAIN_ID: legs_for_if(id_step, legs, {})}
    derived = {step["name"]: legs_for_if(step, legs, legs_by_id)
               for step in steps}
    return steps, derived


def python_versions_steps(job):
    """The python-versions job's steps, pinned to the landed three."""
    steps = read_steps(job, "python-versions")
    if len(steps) != 3:
        refuse(f"[{len(steps)} steps]",
               "expected exactly three steps in the python-versions job: "
               "checkout, setup-python and the behavioral suite")
    # Indexed rather than unpacked: the length pin above is a refusal pylint
    # cannot see through, and W0632 reads the list as possibly short.
    checkout = steps[0]
    setup_python = steps[1]
    suite = steps[2]
    for step, prefix in ((checkout, "actions/checkout@"),
                         (setup_python, "actions/setup-python@")):
        if step["name"] is not None or step["if"] is not None:
            refuse("[step]", f"the python-versions step carrying "
                             f"`{prefix}` carries a name or condition this "
                             "pin does not model")
    if not (checkout["uses"] or "").startswith("actions/checkout@"):
        refuse("[step dash]",
               "expected a dash-`uses:` actions/checkout@ step as the "
               "python-versions job's first step")
    if not (setup_python["uses"] or "").startswith("actions/setup-python@"):
        refuse("[step dash]",
               "expected a dash-`uses:` actions/setup-python@ step as the "
               "python-versions job's second step")
    if suite["name"] != "Run the behavioral suite":
        refuse("[named step]",
               "expected the python-versions job's behavioral-suite step")
    if suite["if"] is not None:
        refuse(suite["if"], "the python-versions behavioral suite carries "
                            "an `if:` this pin does not model")
    return suite["name"]


def read_table(text):
    """The README coverage table as {row label: {column key: bool}}.

    Only the table's own lines are read: the one `| Check |` header, its
    `---` separator, and the run of `|`-led data rows that follows. A blank
    or prose line ends the table; a later fenced table is a table of its
    own, so a second `| Check |` header refuses rather than let the pin
    choose between two tables.
    """
    lines = text.splitlines()
    header = [line for line in lines
              if line.strip().startswith("| Check |")]
    if len(header) != 1:
        refuse(f"[{len(header)} matching lines]",
               "expected exactly one `| Check |` table header row")
    start = next(index for index, line in enumerate(lines)
                 if line.strip().startswith("| Check |"))
    cells = [cell.strip() for cell in header[0].strip().strip("|").split("|")]
    if cells != ["Check"] + list(HEADER):
        refuse(header[0], "the coverage table's columns are not the ones "
                          "this pin reads")
    rows = {}
    separator_seen = False
    for line in lines[start + 1:]:
        if not line.strip().startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not separator_seen:
            if any(cell != "---" for cell in cells):
                refuse(line, "the coverage table's separator row is not the "
                             "`---` row this pin reads")
            separator_seen = True
            continue
        if len(cells) != len(HEADER) + 1:
            refuse(line, "a coverage table row with a cell count this pin "
                         "does not model")
        label = cells[0]
        if label not in ROW_STEPS:
            refuse(line, "a README coverage row this pin does not model")
        if label in rows:
            refuse(line, "a duplicated README coverage row")
        row = {}
        for column, cell in zip(COLUMNS, cells[1:]):
            # Exact `yes`, exact `no`, or the landed `no — <reason>` prose.
            # A prefix test admits `nope` as a claim, so the grammar is
            # exact with one prose arm; anything else refuses.
            if cell == "yes":
                row[column] = True
            elif cell == "no" or cell.startswith("no —"):
                row[column] = False
            else:
                refuse(line, f"a `{column}` cell outside the yes/no grammar "
                             "this pin reads")
        rows[label] = row
    if not separator_seen:
        refuse(header[0], "the coverage table carries no separator row")
    return rows


def covers(workflow_text, readme_text):
    """The pin: every README row's cells equal the legs the workflow grants.

    `Refused` on any shape the pin does not model; `AssertionError` -- the
    suite's ordinary red -- on either drift direction, naming the row, the
    legs and the steps involved.
    """
    lines = structural(workflow_text.splitlines())
    jobs = bare(lines, JOBS, "jobs:", "the workflow")
    tail = between(lines, jobs)
    spans = {anchor[2].strip()[:-1]: job_span(tail, anchor)
             for anchor in at_indent(tail, JOB, r"\S.*:")}
    if set(spans) != {"shellcheck", "suites", "python-versions"}:
        refuse(f"[{sorted(spans)}]",
               "expected exactly the `shellcheck`, `suites` and "
               "`python-versions:` jobs under `jobs:`")

    steps, derived = suites_legs(spans["suites"])
    versions_suite_step = python_versions_steps(spans["python-versions"])

    table = read_table(readme_text)
    missing_rows = sorted(set(ROW_STEPS) - set(table))
    if missing_rows:
        raise AssertionError(
            f"the README coverage table no longer carries {missing_rows}, "
            "which this pin maps to workflow steps: the table was moved or "
            "a row deleted, and the cells it held are unpinned")
    swept = set()
    for label, row in table.items():
        step_names = ROW_STEPS[label]
        absent = [name for name in step_names if name not in derived]
        if absent:
            raise AssertionError(
                f"the README row {label!r} maps to workflow steps {absent} "
                "that the workflow no longer carries: the step was renamed "
                "or removed without moving the table row")
        expected = frozenset.intersection(
            *(derived[name] for name in step_names))
        if versions_suite_step in step_names:
            expected = expected | {"versions"}
        claimed = {column for column, yes in row.items() if yes}
        for leg in sorted(claimed - expected):
            raise AssertionError(
                f"the README row {label!r} claims the `{leg}` leg, but no "
                "mapped step runs it there: "
                + "; ".join(f"{name} runs on {sorted(derived[name])}"
                            for name in step_names))
        for leg in sorted(expected - claimed):
            raise AssertionError(
                f"the workflow runs the {label!r} check on the `{leg}` leg, "
                "but the README cell denies it: the table row and the "
                "step's `if:` disagree")
        swept.update(name for name in step_names if name in derived)
    for step in steps:
        if step["if"] is None:
            continue
        if step["name"] in swept or step["name"] in EXEMPT_STEPS:
            continue
        raise AssertionError(
            f"the workflow scopes {step['name']!r} with an `if:` that no "
            "README row claims and no exemption names: the table and the "
            "workflow disagree")


def main():
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <repository root>",
              file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    for relative in (WORKFLOW, README):
        if not (root / relative).is_file():
            print(f"suite_legs_covers_readme: {relative} must exist",
                  file=sys.stderr)
            return 3
    try:
        covers((root / WORKFLOW).read_text(), (root / README).read_text())
    except Refused as refused:
        print(f"suite_legs_covers_readme: {refused}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
