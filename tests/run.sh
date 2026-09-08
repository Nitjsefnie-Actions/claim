#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$(mktemp -d "$ROOT/tests/.run.XXXXXX")"
mkdir "$RUN/bin"
ln -s "$ROOT/tests/gh.sh" "$RUN/bin/gh"
export PATH="$RUN/bin:$PATH"
export GH_TOKEN REPOSITORY ISSUE ACTOR ACTOR_TYPE GH_CASE

reset_case() {
  GH_TOKEN=test-token
  REPOSITORY=owner/project
  ISSUE=7
  ACTOR=octo-claimant
  ACTOR_TYPE=User
  body=
  expected_error=
}

expect_gh() {
  local response=$1 ordinal
  shift
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], separators=(",", ":")))' "$@" >> "$GH_CASE/expected.jsonl"
  ordinal=$(wc -l < "$GH_CASE/expected.jsonl")
  printf '%s' "$response" > "$GH_CASE/response.$((ordinal))"
}

expect_gh_failure() {
  local status=$1 error=$2 ordinal
  shift 2
  expect_gh '' "$@"
  ordinal=$(wc -l < "$GH_CASE/expected.jsonl")
  ordinal=$((ordinal))
  printf '%s' "$status" > "$GH_CASE/response.$ordinal.status"
  printf '%s\n' "$error" > "$GH_CASE/response.$ordinal.stderr"
}

run_claim() {
  local expected_status=$1 expected_output=${2-} status=0 failed=0
  BODY="$body" python3 "$ROOT/claim.py" > "$GH_CASE/stdout" 2> "$GH_CASE/stderr" || status=$?
  if [[ $status != "$expected_status" ]]; then
    printf '  exit status: expected %s, got %s\n' "$expected_status" "$status"
    failed=1
  fi
  printf '%s' "$expected_output" > "$GH_CASE/expected.stdout"
  if ! diff -u "$GH_CASE/expected.stdout" "$GH_CASE/stdout"; then failed=1; fi
  if ! diff -u "$GH_CASE/expected.jsonl" "$GH_CASE/calls.jsonl"; then failed=1; fi
  if [[ -n $expected_error ]]; then
    printf '%s\n' "$expected_error" > "$GH_CASE/expected.stderr"
  else
    : > "$GH_CASE/expected.stderr"
  fi
  if ! diff -u "$GH_CASE/expected.stderr" "$GH_CASE/stderr"; then failed=1; fi
  if grep -Fq 'Traceback' "$GH_CASE/stderr"; then
    printf '  unexpected traceback\n'
    failed=1
  fi
  return "$failed"
}

sentence() {
  body='please /claim this when you can'
  run_claim 0 $'not a command: please /claim this when you can\n'
}

multiline() {
  body=$'/claim\nthis is a second line'
  run_claim 0 $'not a command: /claim\n'
}

interior_cr() {
  body=$'hello there\r\nsecond line'
  run_claim 0 $'not a command: hello there\n'
}

metacharacters() {
  local result=0
  # The literal shell syntax must reach the child unchanged, including both quotes.
  # shellcheck disable=SC2016
  body='$(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'
  body+=$'\nsecond line'
  (cd "$GH_CASE" && run_claim 0 $'not a command: $(touch /tmp/pwned) $(touch pwned) `touch backtick-pwned` '\''single'\'' "double"'$'\n') || result=$?
  if [[ -e $GH_CASE/pwned || -e $GH_CASE/backtick-pwned || -e /tmp/pwned ]]; then
    printf '  comment body executed a shell side effect\n'
    result=1
  fi
  return "$result"
}

already_assigned() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

trimmed_command() {
  body=$' \t/claim \t\r'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

blank_lines_around_command() {
  body=$'\n \t\r\n/claim\n \t\r\n'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

whitespace_only() {
  body=$' \t\r\n '
  run_claim 0 $'not a command: \n'
}

claimed_by_others() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"}]}' api repos/owner/project/issues/7
  # Backticks here are Markdown in the expected comment, not shell substitutions.
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claimed_by_three() {
  body=/claim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"bob"},{"login":"carol"}]}' api repos/owner/project/issues/7
  # shellcheck disable=SC2016
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=This issue is already claimed by @alice, @bob, @carol. Comment `/unclaim` (or `/release`) if you are giving it up.' --silent
  run_claim 0
}

claim_accepted() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Assigned to @octo-claimant.' --silent
  run_claim 0
}

claim_accepted_elsewhere() {
  body=/claim
  ACTOR=river-helper
  REPOSITORY=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api -X POST repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper' --silent
  expect_gh '{"state":"open","assignees":[{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments -f 'body=Assigned to @river-helper.' --silent
  run_claim 0
}

claim_rejected() {
  body=/claim
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '{"state":"open","assignees":[{"login":"someone-else"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=GitHub would not accept @octo-claimant as an assignee here. That usually means the account needs to have commented on or been granted access to this repository.' --silent
  run_claim 1
}

assignment_post_forbidden() {
  body=/claim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  run_claim 1
}

unclaim_delete_forbidden() {
  body=/unclaim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  run_claim 1
}

comment_forbidden() {
  body=/claim
  expected_error='gh: Resource not accessible by integration (HTTP 403)'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh_failure 1 'gh: Resource not accessible by integration (HTTP 403)' \
    api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 1
}

unclaim_not_assigned() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you are not assigned to this issue, so there is nothing to give up.' --silent
  run_claim 0
}

unclaim_one_of_two() {
  body=/unclaim
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api -X DELETE repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=Unassigned @octo-claimant.' --silent
  run_claim 0
}

release_one_of_two() {
  body=/release
  ACTOR=river-helper
  REPOSITORY=other-team/widget.tools
  ISSUE=42
  expect_gh '{"state":"open","assignees":[{"login":"alice"},{"login":"river-helper"}]}' api repos/other-team/widget.tools/issues/42
  expect_gh '' api -X DELETE repos/other-team/widget.tools/issues/42/assignees -f 'assignees[]=river-helper' --silent
  expect_gh '' api repos/other-team/widget.tools/issues/42/comments -f 'body=Unassigned @river-helper.' --silent
  run_claim 0
}

closed_issue() {
  body=/claim
  expect_gh '{"state":"closed","assignees":[]}' api repos/owner/project/issues/7
  run_claim 0
}

malformed_snapshot() {
  body=/claim
  expected_error='parse error: Expecting property name enclosed in double quotes: line 1 column 17 (char 16)'
  expect_gh '{"state":"open",' api repos/owner/project/issues/7
  run_claim 1
}

missing_assignees() {
  body=/claim
  expected_error='issue snapshot must contain an assignees array'
  expect_gh '{"state":"open"}' api repos/owner/project/issues/7
  run_claim 1
}

pull_request() {
  body=/unclaim
  expect_gh '{"state":"open","pull_request":{"url":"https://api.github.com/repos/owner/project/pulls/7"},"assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  run_claim 0
}

bot_actor() {
  body=/release
  ACTOR_TYPE=Bot
  run_claim 0 $'not a user: Bot\n'
}

organization_actor() {
  body=/claim
  ACTOR_TYPE=Organization
  run_claim 0 $'not a user: Organization\n'
}

mannequin_actor() {
  body=/claim
  ACTOR_TYPE=Mannequin
  run_claim 0 $'not a user: Mannequin\n'
}

empty_actor_type() {
  body=/claim
  ACTOR_TYPE=
  expected_error='invalid actor-type: expected a nonempty account type'
  run_claim 1
}

multiline_actor_type() {
  body=/claim
  ACTOR_TYPE=$'Bot\nUser'
  run_claim 0 $'not a user: Bot\n'
}

missing_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

null_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"state":null,"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

nonstring_state() {
  body=/claim
  expected_error='issue snapshot must contain a state string'
  expect_gh '{"state":42,"assignees":[]}' api repos/owner/project/issues/7
  run_claim 1
}

unknown_state() {
  body=/claim
  expect_gh '{"state":"unknown","assignees":[]}' api repos/owner/project/issues/7
  run_claim 0
}

malformed_confirm() {
  body=/claim
  expected_error='parse error: Expecting property name enclosed in double quotes: line 1 column 17 (char 16)'
  expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
  expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  expect_gh '{"state":"open",' api repos/owner/project/issues/7
  run_claim 1
}

invalid_issue() {
  body=/claim
  ISSUE='7/comments?x=1'
  expected_error='invalid issue: expected digits'
  run_claim 1
}

invalid_repository() {
  body=/claim
  REPOSITORY='owner/project/issues'
  expected_error='invalid repository: expected owner/name'
  run_claim 1
}

repository_query() {
  body=/claim
  REPOSITORY='owner/project?x=1'
  expected_error='invalid repository: expected owner/name'
  run_claim 1
}

nbsp_noncommand() {
  body=$'\302\240/claim\302\240'
  run_claim 0 $'not a command: \302\240/claim\302\240\n'
}

em_space_noncommand() {
  body=$'\342\200\203/claim\342\200\203'
  run_claim 0 $'not a command: \342\200\203/claim\342\200\203\n'
}

ascii_control_trim() {
  body=$'\v\f/claim\v\f'
  expect_gh '{"state":"open","assignees":[{"login":"octo-claimant"}]}' api repos/owner/project/issues/7
  expect_gh '' api repos/owner/project/issues/7/comments -f 'body=@octo-claimant you already have this one.' --silent
  run_claim 0
}

# The C0 separators are NOT whitespace to the shell's [[:space:]], so a body
# delimited by them was never a command. Python's argument-less str.strip()
# does treat them as whitespace, which is exactly the widening this pins shut:
# restoring it makes a body the specification rejects into a valid command.
unit_separator_noncommand() {
  body=$'\037/claim\037'
  run_claim 0 $'not a command: \037/claim\037\n'
}

read_transport_status() {
  body=/claim
  expected_error='gh: transport unavailable'
  expect_gh_failure 42 'gh: transport unavailable' api repos/owner/project/issues/7
  run_claim 42
}

invalid_assignee_snapshot() {
  local assignees=$1 read=$2
  expected_error='issue snapshot assignees must be objects with string logins'
  if [[ $read == initial ]]; then
    body=/unclaim
  else
    body=/claim
    expect_gh '{"state":"open","assignees":[]}' api repos/owner/project/issues/7
    expect_gh '' api -X POST repos/owner/project/issues/7/assignees -f 'assignees[]=octo-claimant' --silent
  fi
  expect_gh "{\"state\":\"open\",\"assignees\":$assignees}" api repos/owner/project/issues/7
  run_claim 1
}

null_login_initial() { invalid_assignee_snapshot '[{"login":null}]' initial; }
null_login_confirm() { invalid_assignee_snapshot '[{"login":null}]' confirm; }
null_assignee_initial() { invalid_assignee_snapshot '[null]' initial; }
null_assignee_confirm() { invalid_assignee_snapshot '[null]' confirm; }
missing_login_initial() { invalid_assignee_snapshot '[{}]' initial; }
missing_login_confirm() { invalid_assignee_snapshot '[{}]' confirm; }

action_contract() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import ast
import re
import sys

root = Path(sys.argv[1])
action = (root / "action.yml").read_text()
# Pin this small manifest's explicit layout rather than adding a YAML dependency.
# Full YAML/schema validation belongs to the actionlint workflow.
lines = "\n".join(line for line in action.splitlines()
                  if line.strip() and not line.lstrip().startswith("#"))
inputs, runs = lines.split("\nruns:\n")
inputs = inputs.split("\ninputs:\n")[1]
step = re.fullmatch(
    r"  using: composite\n  steps:\n    - name: [^\n]+\n"
    r"      shell: bash\n      env:\n(?P<env>(?:        [^\n]+\n)+)"
    r"      run: (?P<run>[^\n]+)", runs)
assert step, "expected one claim step with shell: bash and explicit env/run"
assert "${{" not in step["run"], "expressions must not appear in run values"
assert step["run"] == "'python3 \"$GITHUB_ACTION_PATH/claim.py\"'", \
    "claim run must stay quoted and invoke Python with the quoted action path"
env = {}
for line in step["env"].splitlines():
    name, value = line.strip().split(": ", 1)
    assert name not in env, f"duplicate environment name: {name}"
    env[name] = value
script = ast.parse((root / "claim.py").read_text())
script_variables = {
    node.slice.value for node in ast.walk(script)
    if isinstance(node, ast.Subscript)
    and ast.unparse(node.value) == "os.environ"
    and isinstance(node.slice, ast.Constant)
}
# GH_TOKEN is consumed by gh, the script's API client, through its environment.
assert set(env) == script_variables | {"GH_TOKEN"}, "claim step env must match script dependencies"
specs = re.findall(r"^  ([a-z-]+):\n((?:    [^\n]+(?:\n|$))+)", inputs, re.M)
assert len(specs) == 6 and len(dict(specs)) == 6, "expected six distinct inputs"
specs = dict(specs)
expected_inputs = set()
for name, value in env.items():
    binding = re.fullmatch(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", value)
    assert binding, f"{name} must bind an action input"
    expected = "token" if name == "GH_TOKEN" else name.lower().replace("_", "-")
    assert binding[1] == expected, f"{name} must bind inputs.{expected}"
    expected_inputs.add(expected)
    default = re.findall(r"^    default: (.+)$", specs[expected], re.M)
    assert len(default) == 1 and default[0].strip() not in ("", "null", "~"), \
        f"{expected} needs a default"
assert set(specs) == expected_inputs, "inputs must match the environment bindings"
PY
}

pr_gate_contract() {
  python3 - "$ROOT" <<'PY'
from pathlib import Path
import ast
import re
import sys

path = Path(sys.argv[1]) / ".github/workflows/pr-gate.yml"
assert path.is_file(), "pr-gate workflow must exist"
# Like action_contract, accept this manifest's explicit block layout without
# a YAML dependency. actionlint owns full YAML/schema validation.
nodes = {}
parents = [(-1, ())]
sequences = {}
for raw in path.read_text().splitlines():
    line = re.split(r"\s+#", raw, maxsplit=1)[0].rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    while parents[-1][0] >= indent:
        parents.pop()
    parent = parents[-1][1]
    entry = line.strip()
    if entry.startswith("- "):
        index = sequences.get(parent, 0)
        sequences[parent] = index + 1
        parent += (str(index),)
        nodes[parent] = None
        parents.append((indent, parent))
        indent += 2
        entry = entry[2:]
    pair = re.fullmatch(r"([^:]+):(?:\s+(.*))?", entry)
    assert pair, f"expected explicit workflow mapping: {raw}"
    key, value = pair[1].strip(), pair[2]
    if key.startswith(("'", '"')):
        key = ast.literal_eval(key)
    if value is not None:
        value = value.strip()
        if value.startswith(("'", '"')):
            value = ast.literal_eval(value)
        elif value in ("true", "false"):
            value = value == "true"
        elif value.isdecimal():
            value = int(value)
        if isinstance(value, str) and value.startswith("${{") and value.endswith("}}"):
            value = "${{ " + value[3:-2].strip() + " }}"
    node = parent + (key,)
    assert node not in nodes, f"duplicate workflow key: {'.'.join(node)}"
    nodes[node] = value
    if value is None:
        parents.append((indent, node))

expected = {
    "name": "pr-gate",
    "on/pull_request_target/types": "[opened, edited, reopened]",
    "permissions/contents": "read",
    "permissions/issues": "read",
    "permissions/pull-requests": "write",
    "concurrency/group": "pr-gate-${{ github.event.pull_request.number }}",
    "concurrency/cancel-in-progress": False,
    "jobs/pr-gate/if": "github.event.pull_request.user.type != 'Bot'",
    "jobs/pr-gate/runs-on": "ubuntu-latest",
    "jobs/pr-gate/timeout-minutes": 5,
    "jobs/pr-gate/steps/0/uses":
        "Nitjsefnie-Actions/pr-gate@44437212f1b931f53433b16455bb05aff67ad21e",
    "jobs/pr-gate/steps/0/with/github-token": "${{ github.token }}",
    "jobs/pr-gate/steps/0/with/repository": "${{ github.repository }}",
    "jobs/pr-gate/steps/0/with/pull-request-number": "${{ github.event.pull_request.number }}",
    "jobs/pr-gate/steps/0/with/pull-request-author": "${{ github.event.pull_request.user.login }}",
}
expected = {tuple(key.split("/")): value for key, value in expected.items()}
for node in list(expected):
    for length in range(1, len(node)):
        expected.setdefault(node[:length], None)
assert set(nodes) == set(expected), \
    f"unexpected workflow structure: extra={set(nodes) - set(expected)}, missing={set(expected) - set(nodes)}"
for node, value in expected.items():
    actual = nodes[node]
    if node == ("on", "pull_request_target", "types"):
        assert actual.startswith("[") and actual.endswith("]"), "expected explicit activity list"
        actual = "[" + ", ".join(part.strip().strip("'\"") for part in actual[1:-1].split(",")) + "]"
    if node == ("jobs", "pr-gate", "if"):
        if actual.startswith("${{") and actual.endswith("}}"):
            actual = actual[3:-2].strip()
        actual = re.sub(r"\s*!=\s*", " != ", actual)
    assert actual == value, f"wrong workflow value at {'/'.join(node)}: {actual!r} != {value!r}"
PY
}

cases=(sentence multiline interior_cr metacharacters already_assigned trimmed_command
  blank_lines_around_command whitespace_only claimed_by_others claimed_by_three claim_accepted
  claim_accepted_elsewhere claim_rejected unclaim_not_assigned unclaim_one_of_two release_one_of_two
  closed_issue malformed_snapshot missing_assignees pull_request bot_actor
  organization_actor mannequin_actor invalid_issue invalid_repository repository_query
  assignment_post_forbidden unclaim_delete_forbidden comment_forbidden action_contract pr_gate_contract
  empty_actor_type multiline_actor_type missing_state null_state nonstring_state
  unknown_state malformed_confirm
  nbsp_noncommand em_space_noncommand ascii_control_trim
  unit_separator_noncommand read_transport_status
  null_login_initial null_login_confirm null_assignee_initial null_assignee_confirm
  missing_login_initial missing_login_confirm)
failures=0
for case_name in "${cases[@]}"; do
  GH_CASE="$RUN/$case_name"
  mkdir "$GH_CASE"
  : > "$GH_CASE/expected.jsonl"
  : > "$GH_CASE/calls.jsonl"
  reset_case
  if "$case_name"; then
    printf 'PASS %s\n' "$case_name"
  else
    printf 'FAIL %s\n' "$case_name"
    failures=$((failures + 1))
  fi
done
printf '%s cases, %s failures\n' "${#cases[@]}" "$failures"
if (( failures )); then
  printf 'Artifacts: %s\n' "$RUN"
  exit 1
fi
rm -r -- "$RUN"
