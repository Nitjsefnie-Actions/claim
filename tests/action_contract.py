#!/usr/bin/env python3
"""The action.yml contract pin, run by the action_contract case."""

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
# The setup step's pin and `with:` block stay unread: a bump moves them.
step = re.fullmatch(
    r"  using: composite\n  steps:\n"
    r"    - name: [^\n]+\n      id: (?P<setup>[a-z][a-z0-9_-]*)\n"
    r"      uses: actions/setup-python@[^\n]+\n"
    r"      with:\n(?:        [^\n]+\n)+"
    r"    - name: [^\n]+\n"
    r"      shell: bash\n      env:\n(?P<env>(?:        [^\n]+\n)+)"
    r"      run: (?P<run>[^\n]+)", runs)
assert step, ("expected an interpreter setup step with an id, then one claim"
              " step with shell: bash and explicit env/run")
assert "${{" not in step["run"], "expressions must not appear in run values"
assert step["run"] == "'\"$CLAIM_PYTHON\" \"$GITHUB_ACTION_PATH/claim.py\"'", \
    "claim run must stay quoted and invoke the quoted interpreter path with the quoted action path"
env = {}
for line in step["env"].splitlines():
    name, value = line.strip().split(": ", 1)
    assert name not in env, f"duplicate environment name: {name}"
    env[name] = value
# The interpreter path arrives as environment data, never as program text.
interpreter = env.pop("CLAIM_PYTHON", None)
assert interpreter is not None, "the claim step must receive the interpreter path as CLAIM_PYTHON"
assert re.fullmatch(r"\$\{\{\s*steps\." + re.escape(step["setup"])
                    + r"\.outputs\.python-path\s*\}\}", interpreter), \
    "CLAIM_PYTHON must bind the setup step's python-path output"
script = ast.parse((root / "claim.py").read_text())
script_variables = {
    f"CLAIM_{node.args[0].value}" for node in ast.walk(script)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name) and node.func.id == "input_env"
    and len(node.args) == 1 and isinstance(node.args[0], ast.Constant)
}
# GH_TOKEN is consumed by gh, the script's API client, through its environment.
assert set(env) == script_variables | {"GH_TOKEN"}, "claim step env must match script dependencies"
specs = re.findall(r"^  ([a-z-]+):\n((?:    [^\n]+(?:\n|$))+)", inputs, re.M)
assert len(specs) == 8 and len(dict(specs)) == 8, "expected eight distinct inputs"
specs = dict(specs)
expected_inputs = set()
for name, value in env.items():
    binding = re.fullmatch(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", value)
    assert binding, f"{name} must bind an action input"
    expected = ("token" if name == "GH_TOKEN"
                else name.removeprefix("CLAIM_").lower().replace("_", "-"))
    assert binding[1] == expected, f"{name} must bind inputs.{expected}"
    expected_inputs.add(expected)
    default = re.findall(r"^    default: (.+)$", specs[expected], re.M)
    assert len(default) == 1 and default[0].strip() not in ("", "null", "~"), \
        f"{expected} needs a default"
assert set(specs) == expected_inputs, "inputs must match the environment bindings"
