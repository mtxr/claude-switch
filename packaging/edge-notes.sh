#!/usr/bin/env bash
# Usage: edge-notes.sh <owner/repo> <sha> [stable-tag] [previous-edge-sha] [date]
# Prints the markdown body of the rolling `edge` pre-release to stdout.
# Run it inside a clone that has the stable tag and the full history.

set -euo pipefail

repo="${1:?usage: edge-notes.sh <owner/repo> <sha> [stable-tag] [previous-edge-sha] [date]}"
sha="${2:?usage: edge-notes.sh <owner/repo> <sha> [stable-tag] [previous-edge-sha] [date]}"
stable="${3:-}"
previous="${4:-}"
built="${5:-$(date -u +%Y-%m-%d)}"

max_body="${EDGE_NOTES_MAX:-60000}"
max_commits=300
url="${GITHUB_SERVER_URL:-https://github.com}/$repo"
type_re='^([a-z]+)(\(([^)]*)\))?(!)?:[[:space:]]+(.*)$'

short() {
  printf '%.7s' "$1"
}

commit_exists() {
  [ -n "$1" ] && git cat-file -e "$1^{commit}" 2>/dev/null
}

group_heading() {
  case "$1" in
    feat) echo "Features" ;;
    fix) echo "Bug Fixes" ;;
    perf) echo "Performance" ;;
    build) echo "Build" ;;
    ci) echo "CI" ;;
    docs) echo "Documentation" ;;
    *) echo "Other" ;;
  esac
}

group_of() {
  case "$1" in
    feat | fix | perf | build | ci | docs) echo "$1" ;;
    *) echo "other" ;;
  esac
}

render_line() {
  local full="$1" subject="$2" scope="" breaking="" text="$2" pr from to
  if [[ $subject =~ $type_re ]]; then
    scope="${BASH_REMATCH[3]}"
    breaking="${BASH_REMATCH[4]}"
    text="${BASH_REMATCH[5]}"
  fi
  if [[ $text =~ \(#([0-9]+)\) ]]; then
    pr="${BASH_REMATCH[1]}"
    from="(#$pr)"
    to="([#$pr]($url/pull/$pr))"
    text="${text/"$from"/$to}"
  fi
  [ -n "$scope" ] && text="**$scope:** $text"
  [ -n "$breaking" ] && text="**BREAKING** $text"
  printf -- '- %s ([%s](%s/commit/%s))\n' "$text" "$(short "$full")" "$url" "$full"
}

grouped_commits() {
  local range="$1" order="feat fix perf build ci docs other" g full subject type count=0
  local feat="" fix="" perf="" build="" ci="" docs="" other=""
  while IFS=$'\t' read -r full subject; do
    [ -n "$full" ] || continue
    case "$subject" in "chore(main): release"*) continue ;; esac
    type=other
    [[ $subject =~ $type_re ]] && type="$(group_of "${BASH_REMATCH[1]}")"
    case "$type" in
      feat) feat+="$(render_line "$full" "$subject")"$'\n' ;;
      fix) fix+="$(render_line "$full" "$subject")"$'\n' ;;
      perf) perf+="$(render_line "$full" "$subject")"$'\n' ;;
      build) build+="$(render_line "$full" "$subject")"$'\n' ;;
      ci) ci+="$(render_line "$full" "$subject")"$'\n' ;;
      docs) docs+="$(render_line "$full" "$subject")"$'\n' ;;
      *) other+="$(render_line "$full" "$subject")"$'\n' ;;
    esac
    count=$((count + 1))
  done < <(git log --no-merges --max-count="$max_commits" --format='%H%x09%s' "$range")

  if [ "$count" -eq 0 ]; then
    echo "No user-facing commits in this range."
    echo
    return
  fi
  for g in $order; do
    local body="${!g}"
    [ -n "$body" ] || continue
    printf '### %s\n\n%s\n' "$(group_heading "$g")" "$body"
  done
}

body=""

ahead=""
if commit_exists "$stable"; then
  ahead="$(git rev-list --count "$stable..$sha")"
fi

body+="# edge+$(short "$sha")"$'\n\n'
body+="> **Unstable.** This is a rolling build of \`main\` that follows every merged change and is not a stable release. Use the latest stable release unless you want unreleased changes."$'\n\n'
body+="- Commit: [$(short "$sha")]($url/commit/$sha)"$'\n'
body+="- Built: $built"$'\n'
if commit_exists "$stable"; then
  body+="- Based on: [$stable]($url/releases/tag/$stable), the latest stable release (this build is $ahead commits ahead)"$'\n'
else
  body+="- Based on: no stable release yet"$'\n'
fi
body+=$'\n'
body+="Install with \`CSW_CHANNEL=edge\` in \`install.sh\` or update with \`csw update --edge\`. Running \`csw update\` without the flag only follows stable releases."$'\n\n'

if [ -z "$previous" ]; then
  body+="## Since the previous edge build"$'\n\n'
  body+="This is the first edge build."$'\n\n'
elif [ "$previous" = "$sha" ]; then
  body+="## Since the previous edge build ($(short "$previous"))"$'\n\n'
  body+="No new commits: this build is identical to the previous one."$'\n\n'
elif commit_exists "$previous" && git merge-base --is-ancestor "$previous" "$sha" 2>/dev/null; then
  body+="## Since the previous edge build ($(short "$previous"))"$'\n\n'
  body+="[Compare]($url/compare/$previous...$sha)"$'\n\n'
  body+="$(grouped_commits "$previous..$sha")"$'\n\n'
else
  body+="## Since the previous edge build"$'\n\n'
  body+="The previous build ($(short "$previous")) is not an ancestor of this one, so the history was rewritten. See the section below for everything since the last stable release."$'\n\n'
fi

if commit_exists "$stable"; then
  body+="## Since $stable"$'\n\n'
  body+="[Compare]($url/compare/$stable...$sha)"$'\n\n'
  body+="$(grouped_commits "$stable..$sha")"$'\n'
else
  body+="## Recent commits"$'\n\n'
  body+="$(grouped_commits "$sha")"$'\n'
fi

if [ "${#body}" -gt "$max_body" ]; then
  body="${body:0:$max_body}"
  body="${body%$'\n'*}"
  if commit_exists "$stable"; then
    compare="$url/compare/$stable...$sha"
  else
    compare="$url/commits/$sha"
  fi
  body+=$'\n\n'"_The list was truncated. See the [full comparison]($compare)._"$'\n'
fi

printf '%s\n' "$body"
