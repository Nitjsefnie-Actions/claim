#!/usr/bin/env bash
set -euo pipefail

# The comment body arrives on stdin rather than on the command line, because a
# maximum-size comment does not fit in an argument list. The recorded call is
# the argv with the body read off stdin spliced in after the `-` that
# `--input -` reads it from, so a case asserts the transport and the text of
# the comment in one line: a claim.py that passed the body as `-f body=…`
# again would record a different argv and fail the diff.
record_call() {
  # argv and the payload go to the recorder NUL-separated on stdin rather than
  # as arguments. A comment body can be 262,144 bytes and the kernel's limit on
  # a single argument is 131,072, so recording the payload as one — which the
  # previous version did for an ACCEPTED body, having already stopped doing it
  # for a refused one — killed the stub on a body GitHub accepts. The stub
  # died with the shell's 126, which reads like a product failure.
  #
  # The recorder reads and writes bytes, never text: the suite sets no locale,
  # and Python's text encoding follows one. Both sides of the double are
  # UTF-8 whatever LC_ALL says.
  printf '%s\0' "$@" | python3 -c '
import json, sys
args = sys.stdin.buffer.read().decode("utf-8").split("\0")[:-1]
sys.stdout.buffer.write((json.dumps(args, separators=(",", ":")) + "\n").encode("utf-8"))
' >> "$GH_CASE/calls.jsonl"
}

comment_chars() {
  # Read and write bytes, never text: the suite sets no locale, and Python's
  # text encoding follows one. A body is UTF-8 whatever LC_ALL says.
  python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.buffer.read().decode("utf-8"))))'
}

recorded=()
body=
body_index=0
previous=
for arg in "$@"; do
  if [[ $previous == --input && $arg == - ]]; then
    # One capture, not two: `payload` held a second copy of a body that can be
    # 262,144 bytes, and a bash that copies per character makes that the most
    # expensive part of a suite that already builds bodies that size.
    body=$(cat | python3 -c '
import json, sys
sys.stdout.buffer.write(json.loads(sys.stdin.buffer.read().decode("utf-8"))["body"].encode("utf-8"))
')
    body_index=$(( ${#recorded[@]} + 1 ))
  fi
  recorded+=("$arg")
  previous=$arg
done
# GitHub refuses a comment body over 65,536 characters, and a POST it refuses
# is not a comment posted. This stub already fails loudly on an invocation it
# was not told to expect; refusing a body it does not model is the same door
# for the same reason, wherever the body arrived from — without it a case
# cannot tell an answered command from an unanswered one, and a length read
# off a recorded call is only ever a proxy for this.
#
# The count is in CHARACTERS, made in Python, because that is the unit both
# GitHub's limit and claim.py's ceiling are stated in. Bash's ${#body} would
# count characters under a UTF-8 locale and bytes under LC_ALL=C, and the
# suite sets neither, so a runner under LC_ALL=C would refuse a legal
# multibyte body and read as a product defect. Bytes are the unit the kernel
# limits, and that constraint is met structurally instead: record_call keeps
# the body off this command line, so nothing here is bounded by it.
body_chars=
if [[ -n $body ]]; then
  # Measured once and reused: the refusal path used to start python3 twice over
  # a body that may be a quarter of a megabyte, to print one number twice.
  body_chars=$(printf '%s' "$body" | comment_chars)
fi
if (( body_chars > 65536 )); then
  record_call "${recorded[@]}"
  printf 'refused a comment body of %s characters: the limit is 65536\n' \
    "$body_chars" >&2
  exit 92
fi
if [[ -n $body ]]; then
  record_call "${recorded[@]:0:$body_index}" "body=$body" "${recorded[@]:$body_index}"
else
  record_call "${recorded[@]}"
fi

# `gh api user` asks who the configured token posts as, and claim.py calls it
# in every run that gets past the User check. Numbering its answer into the
# response sequence would renumber every later call of every existing case, so
# it is answered outside the sequence while still being recorded above like
# any other call.
#
# The BODY comes from the case's identity.response, else from the suite-wide
# default GH_IDENTITY. The STATUS and STDERR are the case's alone to state: they
# are read from identity.response.status and identity.response.stderr in the
# case directory, whichever of the two body paths won, so a case can say what
# the answer looked like without having to write a body for it. They used to be
# read beside whichever body path won instead, and a probe that failed without
# writing a word could not be stated under that without also writing an empty
# body file to hang them on (#88).
#
# A companion anywhere else is not read now: a case pointing GH_IDENTITY at a
# body carrying its own .status or .stderr gets a bare exit 0, where the old
# resolution found it beside the answer that was served. No case uses that, and
# keeping it would be a branch no case pins.
#
# A status with no body is a probe that failed and wrote nothing to stdout, so
# stdout is empty here and the exit status is the one stated. A stderr with no
# status beside it is NOT that shape: the stub exits 0, claim.py reads the empty
# stdout as a 200 it cannot parse, and the run reports a parse error instead of
# the identity refusal — not a shape gh produces, so state a status whenever you
# state a stderr. With no body and no status and no stderr there is no answer at
# all, and like the sequence path below the stub fails loudly instead of
# inventing one.
if [[ $# -eq 2 && $1 == api && $2 == user ]]; then
  answer=$GH_CASE/identity.response
  answer_status=$answer.status
  answer_stderr=$answer.stderr
  if [[ ! -f $answer ]]; then
    answer=$GH_IDENTITY
  fi
  if [[ ! -f $answer && ! -f $answer_status && ! -f $answer_stderr ]]; then
    printf 'unexpected gh invocation: %s\n' "$(cat "$GH_CASE/calls.jsonl")" >&2
    exit 91
  fi
  if [[ -f $answer ]]; then
    cat "$answer"
  fi
  if [[ -f $answer_stderr ]]; then
    cat "$answer_stderr" >&2
  fi
  if [[ -f $answer_status ]]; then
    exit "$(cat "$answer_status")"
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
