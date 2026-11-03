#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: smoke.sh <path-to-csw>" >&2
  exit 2
fi

csw="$1"
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/.claude.work"
echo '{}' > "$home/.claude.work/.claude.json"
# A profile stored the way csw 1.2 and older did must be moved into its directory.
echo '{}' > "$home/.claude.legacy.json"
HOME="$home"
export HOME
unset CLAUDE_CONFIG_DIR

fail() {
  echo "smoke: $*" >&2
  exit 1
}

"$csw" --version | grep -q '^csw ' || fail "--version"
"$csw" --help | grep -q 'USAGE' || fail "--help"
"$csw" completion bash | grep -q 'csw' || fail "completion bash"
"$csw" completion zsh | grep -q 'csw' || fail "completion zsh"
"$csw" completion fish | grep -q 'csw' || fail "completion fish"
"$csw" man | grep -q '^\.TH CSW 1' || fail "man"
"$csw" hook zsh | grep -q 'csw env --from-cwd' || fail "hook zsh"
"$csw" hook bash | grep -q 'csw env --from-cwd' || fail "hook bash"
"$csw" hook fish | grep -q 'csw env --from-cwd' || fail "hook fish"
"$csw" _profiles | grep -qx 'work' || fail "_profiles"
"$csw" list | grep -q 'work' || fail "list"
[ -f "$home/.claude.legacy/.claude.json" ] || fail "old-style profile was not moved into its directory"
[ ! -e "$home/.claude.legacy.json" ] || fail "old-style profile json was left behind"
"$csw" list | grep -q 'legacy' || fail "list after migration"
if [ "$(uname -s)" = "Linux" ]; then
  "$csw" doctor >/dev/null || fail "doctor"
fi

expected="export CLAUDE_CONFIG_DIR='$home/.claude.work'"
actual=$("$csw" env work)
[ "$actual" = "$expected" ] || fail "env work printed: $actual"

echo "smoke ok: $("$csw" --version)"
