#!/usr/bin/env bash
set -euo pipefail

# Record argv without losing argument boundaries, quoting, or embedded newlines.
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], separators=(",", ":")))' "$@" >> "$GH_CASE/calls.jsonl"
ordinal=$(wc -l < "$GH_CASE/calls.jsonl")
response="$GH_CASE/response.$((ordinal))"
if [[ ! -f $response ]]; then
  printf 'unexpected gh invocation: %s\n' "$(cat "$GH_CASE/calls.jsonl")" >&2
  exit 91
fi
cat "$response"
if [[ -f $response.stderr ]]; then
  cat "$response.stderr" >&2
fi
if [[ -f $response.status ]]; then
  exit "$(cat "$response.status")"
fi
