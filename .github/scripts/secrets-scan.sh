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
# Rules, ignore list and diff attributes come from the base branch, so the
# scanned change cannot exempt its own finding.
base="refs/remotes/origin/${GITHUB_BASE_REF:-main}"
.github/scripts/retry.sh git fetch --no-tags --quiet origin "+refs/heads/${base##*/}:${base}"
if ! git show "${base}:.gitleaks.toml" > "$work/gitleaks.toml" 2>/dev/null \
    || ! grep -qE '^useDefault[[:space:]]*=[[:space:]]*true$' "$work/gitleaks.toml"; then
  printf '[extend]\nuseDefault = true\n' > "$work/gitleaks.toml"
fi
git show "${base}:.gitleaksignore" > "$work/.gitleaksignore" 2>/dev/null || rm -f "$work/.gitleaksignore"
rm -f -- .gitleaksignore
printf '* diff\n' > "$(git rev-parse --git-path info/attributes)"
"$work/gitleaks" detect --verbose --redact --ignore-gitleaks-allow \
  --config "$work/gitleaks.toml" --gitleaks-ignore-path "$work" \
  --log-opts='--all --full-history --diff-filter=uxdb --diff-merges=first-parent'
