#!/usr/bin/env bash
# Compare latest upstream PHP releases against what our gh-pages repo serves
# for DIST. Exit 1 (cron failure -> notification) when any phpnet branch is
# behind; security branches are informational only.
#
# env: DIST (default bullseye), REPO_URL

set -uo pipefail
: "${DIST:=bullseye}"
: "${REPO_URL:=https://greensec.github.io/php-build/repo}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0

echo "branch  latest-upstream          repo-version               status"
while read -r br type; do
    case "$br" in ''|\#*) continue;; esac
    [ "$type" = phpnet ] || continue
    latest=$(curl -fsSL --max-time 15 "https://www.php.net/releases/index.php?json&version=${br}" \
        | grep -o '"version":"[0-9.]*"' | head -1 | cut -d'"' -f4)
    have=$(curl -fsSL --max-time 15 "$REPO_URL/dists/$DIST/main/binary-amd64/Packages" 2>/dev/null \
        | awk -v p="php${br}-cli" '$1 == "Package:" {hit = ($2 == p)} hit && $1 == "Version:" {print $2; exit}')
    if [ -z "$latest" ]; then
        printf "%-7s %-24s %-26s %s\n" "$br" "(fetch failed)" "${have:-none}" "WARN"
        continue
    fi
    if [ -z "$have" ]; then
        printf "%-7s %-24s %-26s %s\n" "$br" "$latest" "none" "MISSING"
        fail=1
    elif dpkg --compare-versions "$have" lt "$latest"; then
        printf "%-7s %-24s %-26s %s\n" "$br" "$latest" "$have" "BEHIND"
        fail=1
    else
        printf "%-7s %-24s %-26s %s\n" "$br" "$latest" "$have" "ok"
    fi
done < "$ROOT/conf/branches.map"
exit $fail
