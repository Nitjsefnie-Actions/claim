#!/usr/bin/env bash
set -uo pipefail
pause=1
until "$@"; do
  status=$?
  (( SECONDS + pause <= 300 )) || exit "$status"
  echo "retry.sh: exit $status, retrying in ${pause}s" >&2
  sleep "$pause"
  pause=$(( pause * 2 ))
done
