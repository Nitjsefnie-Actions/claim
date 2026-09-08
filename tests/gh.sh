#!/usr/bin/env bash
set -euo pipefail

# Record argv without losing argument boundaries, quoting, or embedded newlines.
jq -cn --args '$ARGS.positional' -- "$@" >> "$GH_CASE/calls.jsonl"
response="$GH_CASE/response.$(wc -l < "$GH_CASE/calls.jsonl")"
if [[ ! -f $response ]]; then
  printf 'unexpected gh invocation: %s\n' "$(cat "$GH_CASE/calls.jsonl")" >&2
  exit 91
fi
cat "$response"
