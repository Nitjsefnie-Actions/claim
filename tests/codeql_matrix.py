#!/usr/bin/env python3
"""The CodeQL matrix pin, over .github/workflows/codeql.yml.

Issue #87 deleted the block-layout YAML reader this pin used to walk the
workflow with: a second YAML implementation, growing one refusal arm per
review round, each round narrowing the gap between what it admits and what
YAML admits. The no-package-install rule stands (CONTRIBUTING's promise), so
the reader is not replaced by a parser but by this: a guard that reads only
the lines the pin depends on and refuses rather than parses. It claims no
grammar for the file beyond those lines, so it cannot drift from YAML's
grammar -- it never models one.

The lines the pin depends on, and the only lines it reads:

  - the anchor chain `jobs:` / `  analyze:` / `    strategy:` /
    `      matrix:` / `        include:` / `    steps:`, each a bare key at
    exactly that indentation, exactly once in the file, in that order;
  - exactly one `    name:` under the job;
  - the matrix entries under `include:`: dash lines
    `          - language: <plain>` / `          - build-mode: <plain>`,
    continued by `            <key>: <plain>` lines, and nothing else
    between `include:` and `steps:`;
  - the `        uses:` line naming each guarded step, counted to pin
    exactly one `github/codeql-action/init@` step and one
    `github/codeql-action/analyze@` step;
  - inside each of those two steps: one bare `        with:` and exactly one
    `          languages:` / `          category:` line, value exact.

Everything else -- comments, blank lines, triggers, the job's other keys,
every other step -- is outside the pin and outside the reading.

Refusal is the channel for "this file is not in the shape the pin admits":
a `Refused` becomes exit 3 with the offending line quoted, and never falls
back to a plausible answer. The semantic claims -- every entry complete,
python among the languages, the value consumed at three places -- are
assertions, red the ordinary way.

The admitted VALUE shape is a plain scalar only: no quotes, no tag, no
anchor, no alias, no merge key, no flow collection, no `: ` inside the
value, no trailing comment. Two file-wide refusals close what the narrow
reading cannot: no block scalar anywhere in the workflow, and no tab in any
line's indentation. A value or layout a maintainer wants to spell another
way is a deliberate edit to this pin, not a parser arm.

Why the file-wide refusals are what close the swallowed-structure false
greens that killed the reader: a block scalar's body carries no flow
punctuation and spans every column below its key, so nothing about a line
proves where YAML ends and the scalar begins -- a body can host a copy of a
pinned line (`run: |` in a guarded step hosting `languages:` at the with
indent) and the pin reading only its own lines cannot tell the copy from
the original. Refusing the construct outright is the arm that closes the
class: a block-scalar header is line-final, its header comment is stripped
before the check, and the check splits at the last colon, so a line whose
YAML value is a block scalar always presents the indicator as the head -- no
spelling of the construct reaches the pin as structure. A flow collection
can span lines at any column, but every line
inside it carries flow punctuation, which no bare anchor and no
`- key: value` entry line does, so the shapes the pin reads cannot be
reproduced inside one. The remaining limits, stated rather than assumed:

  - `${{ }}` is normalised for inner spacing everywhere it occurs and
    resolved nowhere, so `matrix . language` reads unequal to
    `matrix.language` -- that direction reddens, never greens.
  - An anchor is never resolved and an alias never followed; both refuse at
    a read line.
  - It reads no trigger, but no trigger key may carry a block scalar
    (nothing in the file may): an `on: |` hosting the job tree as inert
    text is refused by the file-wide arm.
"""

from pathlib import Path
import re
import sys
from typing import NoReturn

FILE = ".github/workflows/codeql.yml"

# Indentation of every read line, fixed by the file's layout. A layout edit
# is a deliberate edit to this pin.
JOBS, JOB, NAME = 0, 2, 4
STRATEGY, STEPS, MATRIX, INCLUDE = 4, 4, 6, 8
STEP, STEP_KEY, WITH_KEY, ENTRY, ENTRY_KEY = 6, 8, 10, 10, 12

# A value starting with any of these is not a plain scalar this pin reads:
# `|`/`>` block scalars, `{`/`[` flow collections, `&` anchors, `*` aliases,
# `!` tags, `'`/`"` quoting, `?` an explicit key. Each changes what the value
# IS, and this pin reads only what it can see.
INDICATORS = "|>{[&*!'\"?"


class Refused(Exception):
    """The file carries a shape this pin does not model."""


def refuse(line, reason) -> NoReturn:
    # Saying the raise is unconditional is what lets the guards that end in
    # a refuse() call narrow the optional they just refused on: the type
    # checker treats a plain call as able to return, and reads every
    # `re.fullmatch` result past its own `not match:` guard as still
    # optional.
    raise Refused(f"{reason}: {line!r}")


def normalise(value):
    # Every `${{ … }}`, not only a wholly-expression value: the job name is
    # `analyze (${{ matrix.language }})`, and normalising only a
    # wholly-expression value left the embedded spelling unnormalised.
    return re.sub(r"\$\{\{.*?\}\}",
                  lambda m: "${{ " + m[0][3:-2].strip() + " }}", value)


def structural(lines):
    """The (index, indent, text) of every non-blank, non-comment line.

    A tab leading a line counts as no indentation to `lstrip(" ")` arithmetic
    while YAML forbids it outright, so a tab-led line is refused rather than
    read at the wrong column.
    """
    kept = []
    for index, line in enumerate(lines):
        if line.strip() and not line.lstrip().startswith("#"):
            lead = line[:len(line) - len(line.lstrip())]
            if "\t" in lead:
                refuse(line, "a tab in a line's indentation, which YAML forbids")
            kept.append((index, len(line) - len(line.lstrip(" ")), line))
    return kept


def no_block_scalar(lines):
    """Refuse every block-scalar value in the file, at any key.

    The pin reads only its own lines, so a block scalar is the one construct
    that can host a copy of a pinned line as inert text: its body carries no
    flow punctuation and spans every column below its key, so nothing about
    a line proves where YAML ends and the scalar begins. The reviewer's
    plants for this class were two valid-YAML false greens. No workflow in
    this repository needs one -- the current file carries none -- so the
    admitted subset is simply: no block scalar anywhere. A maintainer who
    writes one updates this pin deliberately.
    """
    for entry in lines:
        text = entry[2].strip()
        if text.startswith("- "):
            text = text[2:]
        # A header comment is legal after a block-scalar indicator
        # (`run: | # host: x` is real YAML), so everything from ` #` on is
        # comment text or a quoted value's tail -- never the header -- and
        # is truncated before the split. This is also what keeps a healthy
        # line whose comment carries `: |` from refusing.
        text = text.split(" #")[0].rstrip()
        # The header is line-final, so the LAST colon separates it: a plain
        # key may carry a colon that no space follows (`ru:n: |` is real
        # YAML), and partitioning on the first would read the key for the
        # value and let the scalar through.
        _, colon, value = text.rpartition(":")
        head = value.strip()[:1]
        if colon and head in ("|", ">"):
            refuse(entry[2], "a block scalar this pin does not model")


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


def exactly_one(lines, indent, pattern, what):
    """The lines matching `pattern` at exactly `indent`; refuse unless there
    is exactly one. Zero is a missing region -- the file is not in the pin's
    shape. More than one is an ambiguity no reading survives: a duplicate key
    at one indentation is not YAML this pin can choose between."""
    found = [entry for entry in lines
             if entry[1] == indent and re.fullmatch(pattern, entry[2].strip())]
    if len(found) != 1:
        refuse(f"[{len(found)} matching lines]",
               f"expected exactly one {what} at indent {indent}")
    return found[0]


def bare(lines, indent, key):
    """The one line that is exactly `key` at exactly `indent`.

    A value on an anchor line is a block this pin cannot walk: `strategy: |`
    would make every line the pin reads below it inert scalar text. Refused,
    never stepped over.
    """
    found = [entry for entry in lines
             if entry[1] == indent
             and re.fullmatch(re.escape(key) + r".*", entry[2].strip())]
    if len(found) != 1:
        refuse(f"[{len(found)} matching lines]",
               f"expected exactly one bare `{key}` line at indent {indent}")
    entry = found[0]
    if entry[2].strip() != key:
        refuse(entry[2], f"`{key}` must be a bare key, not carry a value")
    return entry


def entry_pairing(lines, include, steps):
    """The matrix entries as dicts, read dash line by continuation line.

    Every line between `include:` and `steps:` is an entry line or a
    continuation, and nothing else -- the include block is closed. An entry
    missing a key reddens in the caller; a key this pin does not know, or
    one appearing twice in an entry, is refused.
    """
    entries = []
    current = None
    for index, indent, line in lines:
        if not (include[0] < index < steps[0]):
            continue
        text = line.strip()
        if indent == ENTRY and text.startswith("- "):
            current = {}
            entries.append(current)
            text = text[2:]
        elif indent != ENTRY_KEY:
            refuse(line, "a line inside the include block that is not an entry")
        if current is None:
            refuse(line, "a line under `include:` before the first entry")
        pair = re.fullmatch(r"(language|build-mode): (\S.*)", text)
        if not pair:
            refuse(line, "a matrix entry line this pin does not model")
        if pair[1] in current:
            refuse(line, f"a duplicate `{pair[1]}` in one matrix entry")
        current[pair[1]] = plain(line, pair[2], pair[1])
    return entries


def guarded_step(lines, steps, action):
    """The span of the one step whose `uses:` names github/codeql-action's
    `action`, plus its bare `with:` line.

    The step is located by its `        uses:` line -- the codeql steps are
    named first (`- name:` on the dash line), so the uses line sits at
    STEP_KEY, and only the checkout step carries `uses:` on its dash. The
    step's own dash is the last `- ` at step indent BETWEEN the `steps:`
    anchor and the uses line -- elsewhere in the file indent-6 dashes are
    `paths-ignore:` and `cron:` entries, not steps -- and the span runs from
    that dash to the next dash at step indent or the region dedenting below
    it; only the span is read.
    """
    prefix = f"github/codeql-action/{action}@"
    uses = [entry for entry in lines
            if entry[1] == STEP_KEY
            and re.fullmatch(r"uses: \S.*", entry[2].strip())
            and entry[2].strip()[len("uses:"):].strip().startswith(prefix)]
    if len(uses) != 1:
        refuse(f"[{len(uses)} matching lines]",
               f"expected exactly one github/codeql-action/{action} step, "
               f"found {len(uses)}: the job would analyse or file nothing")
    dash = [entry for entry in lines
            if steps[0] < entry[0] < uses[0][0] and entry[1] == STEP
            and entry[2].strip().startswith("- ")]
    if not dash:
        refuse(uses[0][2], f"the {action} step's `uses:` sits under no step")
    span = []
    for entry in lines:
        if entry[0] <= dash[-1][0]:
            continue
        if entry[1] < STEP or (entry[1] == STEP
                               and entry[2].strip().startswith("- ")):
            break
        span.append(entry)
    withs = [entry for entry in span
             if entry[1] == STEP_KEY and entry[2].strip() == "with:"]
    if len(withs) != 1:
        refuse(f"[{len(withs)} matching lines]",
               f"expected exactly one bare `with:` in the {action} step")
    return span, withs[0]


def with_value(span, withs, key):
    """The one `key:` line under the span's `with:`, as a plain scalar."""
    found = exactly_one(
        [entry for entry in span
         if withs[0] < entry[0] and entry[1] == WITH_KEY],
        WITH_KEY, rf"{key}: (\S.*)", f"`{key}:` under the step's `with:`")
    return plain(found[2], found[2].strip()[len(key) + 1:], key)


def covers_python(text):
    """The pin: every matrix entry complete, python among the languages, and
    the language consumed by the job name, init's `languages:` and analyze's
    `category:`. `Refused` on any shape the pin does not model."""
    lines = structural(text.splitlines())

    # The anchors are one chain, in order: a same-shape line anywhere else
    # would bind the pin to a region it is not about.
    chain = [bare(lines, indent, key) for indent, key in
             ((JOBS, "jobs:"), (JOB, "analyze:"), (STRATEGY, "strategy:"),
              (MATRIX, "matrix:"), (INCLUDE, "include:"), (STEPS, "steps:"))]
    if [entry[0] for entry in chain] != sorted(entry[0] for entry in chain):
        refuse("<order>", "the anchor chain is out of order")
    _, job, _, _, include, steps = chain

    # The value is consumed, not merely declared: the job is NAMED for the
    # language it analyses, so two matrix entries land as two checks rather
    # than two runs of one check name.
    name = exactly_one(lines, NAME, r"name: \S.*", "job `name:` line")
    if not (job[0] < name[0] < steps[0]):
        refuse(name[2], "the job `name:` must sit under the analyze job")
    named = plain(name[2], name[2].strip()[len("name:"):], "name")
    assert "${{ matrix.language }}" in named, (
        f"the analyze job is named {named!r}, which does not interpolate "
        "matrix.language, so every matrix entry would answer to one check "
        "name and none of them would land as its own check")

    # No block scalar anywhere: the one construct that can host a copy of a
    # pinned line as inert text while the pin reads it as structure. Checked
    # here, after the anchors the pin walks by, so a valued anchor keeps its
    # own refusal naming the key.
    no_block_scalar(lines)

    entries = entry_pairing(lines, include, steps)
    assert entries, (
        "jobs.analyze.strategy.matrix.include declares no entries, so the "
        "job analyses no language at all")
    for number, entry in enumerate(entries):
        for key in ("language", "build-mode"):
            assert key in entry and entry[key].strip(), (
                f"matrix entry {number} declares no usable {key}: it holds "
                f"{sorted(entry)}, and init is handed an empty {key} for it")
    languages = {entry["language"] for entry in entries}
    assert "python" in languages, (
        "no matrix entry declares `language: python`, so claim.py -- the "
        "program that parses the untrusted comment body -- is never "
        f"analysed: the matrix names {sorted(languages)}")

    span, withs = guarded_step(lines, steps, "init")
    read = with_value(span, withs, "languages")
    assert read == "${{ matrix.language }}", (
        f"the init step's languages is {read!r}, not "
        "'${{ matrix.language }}': each matrix entry would otherwise reach "
        "the analysis of some default language set rather than its own")

    span, withs = guarded_step(lines, steps, "analyze")
    read = with_value(span, withs, "category")
    assert read == "/language:${{ matrix.language }}", (
        f"the analyze step's category is {read!r}, not "
        "'/language:${{ matrix.language }}': the SARIF would land with no "
        "category naming the language, so a run could not be found by the "
        "language it analysed")


def main():
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <repository root>",
              file=sys.stderr)
        return 2
    path = Path(sys.argv[1]) / FILE
    if not path.is_file():
        print(f"codeql_matrix_covers_python: {FILE} must exist",
              file=sys.stderr)
        return 3
    try:
        covers_python(path.read_text())
    except Refused as refused:
        print(f"codeql_matrix_covers_python: {refused}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
