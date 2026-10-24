#!/usr/bin/env bash
# Usage: edge-notes-test.sh
# Builds a throwaway git history and checks the edge release notes generator.

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/edge-notes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

git init -q .
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false

commit() {
  echo "$1" >> file
  git add file
  git commit -q -m "$1"
}

failures=0

expect() {
  local label="$1" needle="$2" haystack="$3"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label: missing '$needle'"
    failures=$((failures + 1))
  fi
}

reject() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label: unexpected '$needle'"
    failures=$((failures + 1))
  fi
}

commit "chore: init"
git tag v1.0.0
commit "feat: add alpha (#12)"
commit "fix(doctor): repair beta"
previous="$(git rev-parse HEAD)"
commit "feat!: break gamma"
commit "docs: explain delta"
commit "chore(main): release 1.0.1"
commit "ci: tune epsilon"
commit "perf: speed up zeta"
commit "build: pin eta"
commit "plain message without a type"
head="$(git rev-parse HEAD)"

out="$("$script" owner/repo "$head" v1.0.0 "$previous" 2026-01-02)"
expect "title" "# edge+${head:0:7}" "$out"
expect "warning" "**Unstable.**" "$out"
expect "date" "Built: 2026-01-02" "$out"
expect "stable base" "[v1.0.0](https://github.com/owner/repo/releases/tag/v1.0.0)" "$out"
expect "ahead count" "(this build is 9 commits ahead)" "$out"
expect "previous section" "## Since the previous edge build (${previous:0:7})" "$out"
expect "stable section" "## Since v1.0.0" "$out"
expect "pr link" "([#12](https://github.com/owner/repo/pull/12))" "$out"
reject "pr link quotes" "\"([#12]" "$out"
expect "scope" "**doctor:** repair beta" "$out"
expect "breaking" "**BREAKING** break gamma" "$out"
expect "features heading" "### Features" "$out"
expect "fixes heading" "### Bug Fixes" "$out"
expect "perf heading" "### Performance" "$out"
expect "build heading" "### Build" "$out"
expect "ci heading" "### CI" "$out"
expect "docs heading" "### Documentation" "$out"
expect "other heading" "### Other" "$out"
expect "untyped commit" "plain message without a type" "$out"
expect "compare link" "https://github.com/owner/repo/compare/v1.0.0...$head" "$out"
reject "release commit" "chore(main)" "$out"
reject "release commit text" "release 1.0.1" "$out"

since_previous="$(awk '/^## Since the previous/{f=1;next} /^## Since v/{f=0} f' <<<"$out")"
expect "previous has newer commit" "break gamma" "$since_previous"
reject "previous skips older feat" "add alpha" "$since_previous"
reject "previous skips older fix" "repair beta" "$since_previous"

first="$("$script" owner/repo "$head" v1.0.0 "" 2026-01-02)"
expect "first build" "This is the first edge build." "$first"

same="$("$script" owner/repo "$head" v1.0.0 "$head" 2026-01-02)"
expect "identical build" "this build is identical to the previous one" "$same"

rewritten="$("$script" owner/repo "$head" v1.0.0 0123456789abcdef0123456789abcdef01234567 2026-01-02)"
expect "rewritten history" "the history was rewritten" "$rewritten"
expect "rewritten keeps stable section" "## Since v1.0.0" "$rewritten"

nostable="$("$script" owner/repo "$head" "" "" 2026-01-02)"
expect "no stable" "no stable release yet" "$nostable"
expect "recent commits" "## Recent commits" "$nostable"
expect "recent has feature" "add alpha" "$nostable"

truncated="$(EDGE_NOTES_MAX=600 "$script" owner/repo "$head" v1.0.0 "$previous" 2026-01-02)"
expect "truncated" "The list was truncated" "$truncated"
expect "truncated compare link" "full comparison](https://github.com/owner/repo/compare/v1.0.0...$head)" "$truncated"

empty_range="$("$script" owner/repo "$(git rev-parse v1.0.0)" v1.0.0 "" 2026-01-02)"
expect "empty range" "No user-facing commits in this range." "$empty_range"

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "edge-notes: all checks passed"
