#!/usr/bin/env bash
set -euo pipefail

# Record argv without losing argument boundaries, quoting, or embedded newlines.
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], separators=(",", ":")))' "$@" >> "$GH_CASE/calls.jsonl"

# `gh api user` asks who the configured token posts as, and claim.py calls it
# in every run that gets past the User check. Numbering its answer into the
# response sequence would renumber every later call of every existing case,
# so it is answered outside the sequence from its own fixture — the case's
# identity.response, else the suite-wide default GH_IDENTITY — while still
# being recorded above like any other call. Like the sequence path below, a
# missing answer fails loudly instead of inventing one.
if [[ $# -eq 2 && $1 == api && $2 == user ]]; then
  response=$GH_CASE/identity.response
  if [[ ! -f $response ]]; then
    response=$GH_IDENTITY
  fi
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
  exit 0
fi

# Ordinals count the ordinary calls only, so the identity record above —
# answered outside the sequence — never shifts another call's number. The
# counter needs its own file because calls.jsonl now carries a record the
# sequence does not answer.
ordinal=$(( $(cat "$GH_CASE/sequence") + 1 ))
printf '%s\n' "$ordinal" > "$GH_CASE/sequence"
response="$GH_CASE/response.$ordinal"
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
