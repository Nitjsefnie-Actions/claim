"""One test per case tests/run.sh lists, each run in a bash of its own."""
import os
import subprocess
from pathlib import Path

import pytest

SUITE = Path(__file__).resolve().with_name("run.sh")
CASES = subprocess.run(("bash", "-c", 'source "$1"; printf "%s\\n" "${cases[@]}"', "_", SUITE),
                       check=True, capture_output=True, text=True).stdout.split()


@pytest.fixture(name="case_env")
def fixture_case_env(tmp_path):
    """The case's own directory, the gh stub first on PATH, and the reset values."""
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "gh").symlink_to(SUITE.with_name("gh.sh"))
    (case := tmp_path / "case").mkdir()
    for name in ("expected.jsonl", "calls.jsonl", "sequence", "identity-sequence"):
        (case / name).write_text("0\n" if name.endswith("sequence") else "", encoding="utf-8")
    return case, {**os.environ, "PATH": f"{tmp_path / 'bin'}{os.pathsep}{os.environ['PATH']}",
                  "GH_CASE": str(case), "GH_TOKEN": "test-token",
                  "CLAIM_REPOSITORY": "owner/project", "CLAIM_ISSUE": "7",
                  "CLAIM_ACTOR": "octo-claimant", "CLAIM_ACTOR_TYPE": "User",
                  "CLAIM_MAX_CLAIMS": "-1", "CLAIM_EXPIRE": "-1",
                  "GH_IDENTITY": str(SUITE.with_name("identity.response"))}


@pytest.mark.parametrize("name", CASES)
def test_case(name, case_env):
    case, env = case_env
    # `||` suspends errexit inside the case function, which the cases are written for.
    ran = subprocess.run(("bash", "-c", 'source "$1"; body= expected_error=; "$2" || exit 1', "_",
                          SUITE, name), cwd=SUITE.parent.parent, env=env, capture_output=True,
                         check=False)
    assert ran.returncode == 0, f"{case}:\n{(ran.stdout + ran.stderr).decode(errors='replace')}"
    if (case / "skip").exists():
        pytest.skip((case / "skip").read_text(encoding="utf-8").strip())
