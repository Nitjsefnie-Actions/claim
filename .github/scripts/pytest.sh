#!/usr/bin/env bash
set -euo pipefail
(( $# )) || { echo "usage: pytest.sh PYTEST_ARG..." >&2; exit 2; }
# Off PATH: cases keep their python3.
venv="${RUNNER_TEMP:?}/suite-venv"
python3 -m venv "$venv"
awk '/^pytest==/{f=1} f' .github/workflows/requirements.txt > "$venv.txt"
.github/scripts/retry.sh "$venv/bin/python" -m pip install --require-hashes -r "$venv.txt"
exec "$venv/bin/python" -m pytest "$@"
