#!/usr/bin/env bash
# The one secret scan: tests.yml gates with it, secrets.yml runs it daily.
set -euo pipefail
version=8.30.1
tarball="gitleaks_${version}_linux_x64.tar.gz"
digest=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
.github/scripts/download.sh \
  "https://github.com/gitleaks/gitleaks/releases/download/v${version}/${tarball}" \
  "$work/$tarball"
echo "${digest}  $work/$tarball" | sha256sum -c -
tar xzf "$work/$tarball" -C "$work" gitleaks
exec "$work/gitleaks" detect --verbose --redact --ignore-gitleaks-allow
