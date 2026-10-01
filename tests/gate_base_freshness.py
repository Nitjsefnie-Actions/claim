#!/usr/bin/env python3
"""Require the head being checked out to carry every commit main holds that
touches a file the REQUIRED status checks read as a parameter.

The `main requires green checks` ruleset sets
strict_required_status_checks_policy to false, so a pull request merges on a
green head whose checks ran against a main that had not yet moved. Nothing
compared the two, so a commit that lands on main changing a file a required
check reads is never applied to the pull request before it merges, and the
merge publishes a tree whose green run proved nothing about it.

The set of such files is DERIVED from the workflows under .github/workflows,
not kept in a list here. A remembered list is only as current as the last time
somebody remembered to add to it, which is this defect wearing different
clothes: a gate whose own inputs are enumerated by hand goes stale exactly the
way this check exists to prevent.

The only hand-held entry is REQUIRED_JOBS, because the ruleset that makes a
status context required lives in repository settings, which are not in the
repository. Every name there must still be FOUND in a workflow below or the
run refuses: a job renamed out of every workflow would otherwise shrink the
set in silence, and a narrower set reports green over a wider gate.

Runs on the standard library alone. The workflows are read with a parser for
the block layout this repository uses rather than a YAML dependency, for the
reason action_contract gives: nothing installs one here, and a parser that
refuses a shape it does not model is better than a silent misreading.

    tests/gate_base_freshness.py [--root DIR] [--print-paths]

--print-paths writes the derived set, one path per line, and is how the suite
pins the derivation.
"""

import fnmatch
import re
import subprocess
import sys
from pathlib import Path

# The required status contexts. Hand-held, and only here: a ruleset is
# repository configuration, not a file, so nothing under .github/workflows can
# be asked which jobs it makes required. Each name is still looked up in the
# workflows below, and a name with no job behind it is a refusal rather than a
# silently smaller set.
REQUIRED_JOBS = ("actionlint", "shellcheck", "suites")

# The branch a required check's head is compared against. Not configurable:
# a second branch here would be a second base, and this question has one.
BASE_BRANCH = "main"

# The byte size at which a pathspec argument list is refused rather than
# attempted. The kernel's own limit is `getconf ARG_MAX`, which is not a fixed
# number and not readable from Python, so this is a deliberately low ceiling:
# every repository that reaches it is far past this one's size, and a refusal
# names the cause where an E2BIG from exec would be a traceback.
PATHSPECS_MAX_BYTES = 65536

WORKFLOW_DIR = ".github/workflows"


class GateError(Exception):
    """This run could not establish the answer, and says so instead."""


class WorkflowError(GateError):
    """A workflow whose shape this parser does not model."""


def git(root, *arguments, what):
    """Run one git command in `root` and return its stdout.

    Every call goes through here because a guard that reads its own error as a
    clean tree is the false green this exists to prevent: a non-zero status is
    a refusal naming what was being attempted, never an empty answer.
    """
    command = ("git", "-C", str(root)) + arguments
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        detail = done.stderr.strip() or "no output"
        raise GateError(
            f"cannot {what}: `{' '.join(command)}` exited {done.returncode}: {detail}")
    return done.stdout


# --- reading the workflows -------------------------------------------------
#
# The subset of YAML these workflows use: explicit block mappings, explicit
# sequence entries, and block scalars for `run:`. Every step below refuses a
# shape it does not model rather than guessing at one, because a guessed shape
# yields a smaller path set, and a smaller path set is a green over a gate that
# was never checked.

MAPPING = re.compile(r"^(?P<key>[A-Za-z_][A-Za-z0-9_.-]*):(?:[ \t]+(?P<value>.*))?$")
SEQUENCE = re.compile(r"^- (?P<rest>.+)$")
BLOCK_SCALAR = re.compile(r"^[|>][0-9+-]*$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def skippable(line):
    """A blank line or a whole-line comment, which carries no node.

    Only ever asked of lines OUTSIDE a block scalar: inside one a `#` line is
    the step author's own comment, carried to bash verbatim, and dropping it
    would change what the step runs.
    """
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def block_end(lines, start, indent):
    """The index just past the node whose key sits at `start` with `indent`."""
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if not skippable(line) and indent_of(line) <= indent:
            break
        index += 1
    return index


def block_scalar(lines, start, key_indent, limit):
    """The text of the `|` scalar introduced at `start`, and the index after it.

    The block's indentation is the first non-blank body line's, which is what
    YAML takes as its indicator when the header carries no explicit one. Every
    line is kept, comments included: they are bytes bash receives.
    """
    body = []
    index = start + 1
    while index < limit:
        line = lines[index]
        if line.strip() and indent_of(line) <= key_indent:
            break
        body.append(line)
        index += 1
    leads = [indent_of(line) for line in body if line.strip()]
    lead = min(leads) if leads else key_indent + 2
    return "\n".join(line[lead:] if len(line) > lead else "" for line in body), index


def workflow_steps(text, workflow):
    """{job name: [step, ...]} for one workflow, each step its `run` and `uses`."""
    lines = text.splitlines()
    top = None
    for index, line in enumerate(lines):
        if skippable(line):
            continue
        match = MAPPING.match(line)
        if match and indent_of(line) == 0 and match["key"] == "jobs" \
                and match["value"] is None:
            top = index
            break
    if top is None:
        raise WorkflowError(f"{workflow} has no top-level `jobs:` mapping")

    jobs = {}
    index = top + 1
    while index < len(lines):
        line = lines[index]
        if skippable(line):
            index += 1
            continue
        if indent_of(line) < 2:
            break
        if indent_of(line) != 2:
            raise WorkflowError(
                f"{workflow}: expected a job entry under `jobs:`, found {line!r}")
        match = MAPPING.match(line.strip())
        if not match or match["value"] is not None:
            raise WorkflowError(f"{workflow}: expected a job entry, found {line!r}")
        name = match["key"]
        if name in jobs:
            raise WorkflowError(f"{workflow}: duplicate job {name!r}")
        jobs[name] = (index + 1, block_end(lines, index, 2))
        index = block_end(lines, index, 2)

    return {name: job_steps(lines, name, span, workflow)
            for name, span in jobs.items()}


def job_steps(lines, name, span, workflow):
    start, end = span
    steps = []
    index = start
    while index < end:
        line = lines[index]
        if skippable(line):
            index += 1
            continue
        if indent_of(line) != 4:
            raise WorkflowError(
                f"{workflow}: expected a step list or a job key in job "
                f"`{name}`, found {line!r}")
        match = MAPPING.match(line.strip())
        if not match:
            raise WorkflowError(
                f"{workflow}: expected a job key in job `{name}`, found {line!r}")
        if match["key"] != "steps" or match["value"] is not None:
            # Every other job key — runs-on, strategy, env, permissions — is a
            # mapping or a scalar that never names a file this check reads, and
            # its children sit at an indent a step's own keys also use. Skipping
            # the key's whole block rather than its first line is what keeps
            # `permissions:`'s children from being read as steps.
            index = block_end(lines, index, 4)
            continue
        index = step_entries(lines, name, index + 1, block_end(lines, index, 4), workflow, steps)
    return steps


def step_entries(lines, name, start, end, workflow, steps):
    index = start
    while index < end:
        line = lines[index]
        if skippable(line):
            index += 1
            continue
        if indent_of(line) != 6 or not SEQUENCE.match(line.strip()):
            raise WorkflowError(
                f"{workflow}: expected a step entry in job `{name}`, found {line!r}")
        stop = block_end(lines, index, 6)
        steps.append(step_fields(lines, name, index + 1, stop, workflow))
        index = stop
    return index


def step_fields(lines, name, start, end, workflow):
    """One step's `run:` text and its `uses:` value."""
    step = {"run": None, "uses": None}
    index = start
    while index < end:
        line = lines[index]
        if skippable(line):
            index += 1
            continue
        if indent_of(line) != 8:
            raise WorkflowError(
                f"{workflow}: expected a key in a step of job `{name}`, found {line!r}")
        match = MAPPING.match(line.strip())
        if not match:
            raise WorkflowError(
                f"{workflow}: expected a key in a step of job `{name}`, found {line!r}")
        key, value = match["key"], (match["value"] or "").strip()
        if key == "run":
            if not value or BLOCK_SCALAR.match(value):
                step["run"], index = block_scalar(lines, index, 8, end)
                continue
            step["run"] = value
        elif key == "uses":
            # The value is the reference alone; the `# v4.38.2` after it is a
            # comment, and an action reference never contains a space.
            step["uses"] = value.split()[0] if value else None
        elif not value or BLOCK_SCALAR.match(value):
            # A `with:`/`env:` mapping or a block scalar the step carries but
            # does not execute. Its text is an input to a step, not a file a
            # step reads, and reading one is how an expression's spelling would
            # be mistaken for a path.
            index = block_end(lines, index, 8)
            continue
        index += 1
    return step


# --- the paths a required check reads --------------------------------------

# The platforms expand `${{ }}` before bash sees a byte, so a path a step
# reaches THROUGH an expression is not text this matcher can see. Removing the
# expressions rather than keeping them keeps a resolved value from being read as
# a path; either way the limit is the same and is named in the report.
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.DOTALL)
CANDIDATE = re.compile(r"[A-Za-z0-9._/-]+")


def candidates(text):
    return CANDIDATE.findall(EXPRESSION.sub(" ", text))


def resolve(candidate, files):
    """The tracked files a candidate names, or nothing.

    Resolution against the tree IS the filter: a token that names nothing here
    is not a path this check needs to watch, and a token that names a file or a
    directory is one. There is no shape rule on top of that, because a shape
    rule is a second remembered list — it is what left `tests/identity.response`
    out of a hand-written enumeration in the first place.
    """
    candidate = candidate[2:] if candidate.startswith("./") else candidate
    candidate = candidate.rstrip("/")
    if not candidate:
        return ()
    if any(glob in candidate for glob in "*?["):
        return tuple(f for f in files if fnmatch.fnmatchcase(f, candidate))
    if candidate in files:
        return (candidate,)
    prefix = candidate + "/"
    return tuple(f for f in files if f.startswith(prefix))


def tracked_files(root):
    return tuple(f for f in
                 git(root, "ls-tree", "-r", "--name-only", "--full-tree", "HEAD",
                     what="list the tracked tree").split("\n") if f)


def workflow_names(files):
    return sorted(f for f in files
                  if f.startswith(WORKFLOW_DIR + "/")
                  and (f.endswith(".yml") or f.endswith(".yaml")))


def gate_paths(root):
    """Every tracked file a required check reads, derived from the workflows.

    Every workflow is parsed, not only the ones a required job turns out to be
    in: a workflow this cannot read is a workflow whose steps it cannot account
    for, and skipping it would be the same quiet narrowing the refusal exists
    to stop.
    """
    files = tracked_files(root)
    if not files:
        raise GateError("HEAD tracks no files, so the tree to compare is not there")
    parsed = {}
    for workflow in workflow_names(files):
        parsed[workflow] = workflow_steps(
            git(root, "cat-file", "blob", f"HEAD:{workflow}",
                what=f"read {workflow}"), workflow)
    derived = set()
    for job in REQUIRED_JOBS:
        source = next((steps for steps in parsed.values() if job in steps), None)
        if source is None:
            raise GateError(
                f"no workflow under {WORKFLOW_DIR}/ defines the required job "
                f"`{job}`, so the files the required checks read cannot be built: "
                f"put the job back, or update REQUIRED_JOBS if it was renamed")
        for step in source[job]:
            uses = step["uses"] or ""
            if uses.startswith("./"):
                # A step running a composite action out of THIS repository reads
                # that action's files as its own parameters, and they are not
                # text in this workflow. The directory is taken whole rather
                # than its `action.yml` alone: what the action reaches from
                # inside is the same question this matcher cannot answer, and a
                # partial answer would be a narrower gate than it looks.
                derived.update(files if uses == "./" else resolve(uses, files))
            if not step["run"]:
                continue
            for candidate in candidates(step["run"]):
                derived.update(resolve(candidate, files))
    if not derived:
        raise GateError(
            "the required checks name no file in this tree, so there is nothing "
            "to compare and this run can vouch for nothing")
    return sorted(derived)


# --- the comparison --------------------------------------------------------


def fetch_base(root):
    """Bring main in as it is NOW, not as the checkout left it.

    actions/checkout fetches one commit of one ref by default, so a main that
    moved after that run left nothing here to compare against — which is the
    whole question. Anonymous on purpose: every checkout in this repository
    sets persist-credentials: false and the repository is public.

    --unshallow deepens the ref actually being compared. Without it the grafted
    boundary hides the head's own ancestry, git cannot tell which of main's
    commits the head already carries, and the check reports main's history
    against it — naming commits whose content is sitting in the checkout. That
    is a red nobody can satisfy by rebasing.
    """
    arguments = ["fetch", "--no-tags", "--quiet"]
    if git(root, "rev-parse", "--is-shallow-repository",
           what="ask whether the checkout is shallow").strip() == "true":
        arguments.append("--unshallow")
    arguments += ["origin", f"+refs/heads/{BASE_BRANCH}:refs/remotes/origin/{BASE_BRANCH}"]
    git(root, *arguments, what=f"fetch origin/{BASE_BRANCH}")


def stale_commits(root, head, base, paths):
    """[(sha, subject, [paths])] for the commits base holds that head lacks.

    `--` with nothing after it means EVERY path, so the empty set is refused
    here rather than handed to git: a guard that compares against no paths
    would report the whole of main as fresh.
    """
    if not paths:
        raise GateError("the derived path set is empty, so there is nothing to compare")
    sized = sum(len(path) + 1 for path in paths)
    if sized > PATHSPECS_MAX_BYTES:
        raise GateError(
            f"the derived path set is {sized} bytes, past the {PATHSPECS_MAX_BYTES} "
            f"this run will put in an argument list")
    listing = subprocess.run(
        ("git", "-C", str(root), "log", f"{head}..{base}", "--name-only",
         "--format=%x00%H%x09%s", "--", *paths),
        capture_output=True, text=True)
    if listing.returncode != 0:
        raise GateError(
            f"cannot list what {BASE_BRANCH} holds that this head lacks: "
            f"`git log {head}..{base}` exited {listing.returncode}: "
            f"{listing.stderr.strip() or 'no output'}")
    stale = []
    for chunk in listing.stdout.split("\0"):
        if not chunk.strip():
            continue
        header, _, body = chunk.partition("\n")
        sha, _, subject = header.partition("\t")
        stale.append((sha.strip(), subject.strip(),
                      [line for line in body.split("\n") if line.strip()]))
    return stale


def check(root):
    head = git(root, "rev-parse", "--verify", "HEAD^{commit}",
               what="resolve the checked-out head").strip()
    fetch_base(root)
    base = git(root, "rev-parse", "--verify", f"refs/remotes/origin/{BASE_BRANCH}^{{commit}}",
               what=f"resolve origin/{BASE_BRANCH}").strip()
    paths = gate_paths(root)
    stale = stale_commits(root, head, base, paths)
    if not stale:
        print(f"This head carries every commit on {BASE_BRANCH} that touches "
              f"the {len(paths)} file(s) the required checks read.")
        return 0
    plural = "s" if len(stale) != 1 else ""
    each = "each changes" if len(stale) == 1 else "each change"
    print(f"{BASE_BRANCH} holds {len(stale)} commit{plural} this head does not, "
          f"and {each} a file the required checks read:")
    for sha, subject, touched in stale:
        print(f"  {sha} {subject}")
        for path in touched:
            print(f"    {path}")
    print(f"Rebase onto {BASE_BRANCH} and push again, so this run's checks read "
          f"the files {BASE_BRANCH} reads.")
    return 1


def main(argv):
    root = Path(__file__).resolve().parent.parent
    print_paths = False
    rest = list(argv[1:])
    while rest:
        argument = rest.pop(0)
        if argument == "--print-paths":
            print_paths = True
        elif argument == "--root":
            if not rest:
                print("usage: gate_base_freshness.py [--root DIR] [--print-paths]",
                      file=sys.stderr)
                return 2
            root = Path(rest.pop(0))
        else:
            print(f"unknown argument: {argument}", file=sys.stderr)
            print("usage: gate_base_freshness.py [--root DIR] [--print-paths]",
                  file=sys.stderr)
            return 2
    try:
        if print_paths:
            for path in gate_paths(root):
                print(path)
            return 0
        return check(root)
    except GateError as refusal:
        print(f"head freshness: {refusal}", file=sys.stderr)
        return 1
    except OSError as failure:
        # git could not be run at all — absent from the runner image, or an
        # argument list past what the kernel will exec. Named rather than
        # traced: a refusal is what this run owes the reader, and the exit
        # status is the same either way.
        print(f"head freshness: cannot run git: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))