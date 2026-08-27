#!/usr/bin/env bash
# .github/card.sh — generate data/<YYMMDD>.yml for the upstream repo.
#
# Standalone port of `x repo card` (x-bash/repo, private) so a public
# x-cmd-install/<software> repo can run it on a bare GitHub runner with
# nothing but curl + jq. Output is byte-identical in shape to what
# `x repo card <owner/repo>` emits, so x-cmd-install-stat can consume
# either source.
#
# Cost per run: 1 GraphQL request (16 search counts merged into one
# round-trip) + 1 REST /stats/commit_activity. Well inside the
# 1000 req/h that GITHUB_TOKEN gets per repository.
#
# Usage:  GITHUB_TOKEN=... ./.github/card.sh [owner/repo] [days]
# Default owner/repo comes from the README.md yfm frontmatter.

set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

owner_repo="${1:-}"
days="${2:-90}"

if [ -z "$owner_repo" ]; then
    owner_repo=$(awk -F':[[:space:]]*' '/^owner-repo:/{print $2; exit}' "$root/README.md" | tr -d '[:space:]')
fi
case "$owner_repo" in
    */*) : ;;
    *)   echo "card.sh: bad or missing owner/repo -> '$owner_repo'" >&2; exit 1 ;;
esac

# jq's -L / include resolves relative to the CWD, not to the -L path, on
# jq 1.8 — so inline the module text into every filter instead. Works from
# any working directory and on any jq >= 1.6.
lib="$(cat "$here/card.jq")"

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$token" ] || { echo "card.sh: no GITHUB_TOKEN / GH_TOKEN" >&2; exit 1; }

owner="${owner_repo%/*}"
name="${owner_repo#*/}"

# Four windows: 30d momentum, 90d (label overridable via $days), 180d, 360d.
# GNU date on ubuntu runners; the BSD form is the fallback for local testing.
ago() {
    date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d
}
date30=$(ago 30)
date90=$(ago 90)
date180=$(ago 180)
date360=$(ago 360)

# 16 search strings (4 metrics x 4 windows) passed as whole strings so the
# `>` in `created:>DATE` never reaches a shell/GraphQL parser as an operator.
r="repo:${owner_repo}"
_s1="$r is:pr is:merged created:>$date30"
_s2="$r is:pr is:merged created:>$date90"
_s3="$r is:pr is:merged created:>$date180"
_s4="$r is:pr is:merged created:>$date360"
_s5="$r is:pr state:open created:>$date30"
_s6="$r is:pr state:open created:>$date90"
_s7="$r is:pr state:open created:>$date180"
_s8="$r is:pr state:open created:>$date360"
_s9="$r is:issue state:closed created:>$date30"
_s10="$r is:issue state:closed created:>$date90"
_s11="$r is:issue state:closed created:>$date180"
_s12="$r is:issue state:closed created:>$date360"
_s13="$r is:issue state:open created:>$date30"
_s14="$r is:issue state:open created:>$date90"
_s15="$r is:issue state:open created:>$date180"
_s16="$r is:issue state:open created:>$date360"

query=$(jq -nc \
    --arg o "$owner" --arg n "$name" \
    --arg s1 "$_s1" --arg s2 "$_s2" --arg s3 "$_s3" --arg s4 "$_s4" \
    --arg s5 "$_s5" --arg s6 "$_s6" --arg s7 "$_s7" --arg s8 "$_s8" \
    --arg s9 "$_s9" --arg s10 "$_s10" --arg s11 "$_s11" --arg s12 "$_s12" \
    --arg s13 "$_s13" --arg s14 "$_s14" --arg s15 "$_s15" --arg s16 "$_s16" \
    "$lib"'
     card_query($o; $n;
                $s1;  $s2;  $s3;  $s4;
                $s5;  $s6;  $s7;  $s8;
                $s9;  $s10; $s11; $s12;
                $s13; $s14; $s15; $s16)')

response=$(curl -sS --retry 3 --retry-delay 5 \
    -H "Authorization: bearer $token" \
    -H "Content-Type: application/json" \
    -d "$query" https://api.github.com/graphql)
[ -n "$response" ] || { echo "card.sh: empty GraphQL response for $owner_repo" >&2; exit 1; }

# Hard-fail on a null repository — a renamed/deleted upstream should not
# quietly produce a card full of empty fields.
if [ "$(printf '%s' "$response" | jq -r '.data.a // "null"')" = "null" ]; then
    printf '%s' "$response" | jq -r '.errors[]?.message | "card.sh: graphql: \(.)"' >&2
    echo "card.sh: no repository data for $owner_repo" >&2
    exit 1
fi

data=$(printf '%s' "$response" | jq -r "$lib"' card_search_counts')
{
    read -r merged30;  read -r merged90;  read -r merged180;  read -r merged360
    read -r openpr30;  read -r openpr90;  read -r openpr180;  read -r openpr360
    read -r closei30;  read -r closei90;  read -r closei180;  read -r closei360
    read -r openi30;   read -r openi90;   read -r openi180;   read -r openi360
} <<EOF
$data
EOF

# /stats/commit_activity: 52 weeks of daily counts, public, no 100-cap.
# GitHub computes it asynchronously and answers 202 with an empty body on a
# cold cache, so retry a couple of times before falling back to zeros.
commit_raw=""
for _ in 1 2 3; do
    commit_raw=$(curl -sS -H "Authorization: bearer $token" \
        "https://api.github.com/repos/${owner_repo}/stats/commit_activity" || true)
    case "$(printf '%s' "$commit_raw" | jq -r 'type' 2>/dev/null || echo bad)" in
        array) break ;;
    esac
    commit_raw=""
    sleep 5
done
if [ -n "$commit_raw" ]; then
    commit_data=$(printf '%s' "$commit_raw" | jq -r "$lib"' card_commit_counts')
else
    echo "card.sh: commit_activity unavailable for $owner_repo, recording 0" >&2
    commit_data=$'0\n0\n0\n0'
fi
{
    read -r commit30; read -r commit90; read -r commit180; read -r commit360
} <<EOF
$commit_data
EOF

collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '%s' "$response" | jq -r \
    --argjson merged30 "$merged30" --argjson merged90 "$merged90" \
    --argjson merged180 "$merged180" --argjson merged360 "$merged360" \
    --argjson openpr30 "$openpr30" --argjson openpr90 "$openpr90" \
    --argjson openpr180 "$openpr180" --argjson openpr360 "$openpr360" \
    --argjson closei30 "$closei30" --argjson closei90 "$closei90" \
    --argjson closei180 "$closei180" --argjson closei360 "$closei360" \
    --argjson openi30 "$openi30" --argjson openi90 "$openi90" \
    --argjson openi180 "$openi180" --argjson openi360 "$openi360" \
    --argjson commit30 "$commit30" --argjson commit90 "$commit90" \
    --argjson commit180 "$commit180" --argjson commit360 "$commit360" \
    --arg date30 "$date30" --arg date90 "$date90" \
    --arg date180 "$date180" --arg date360 "$date360" \
    --arg days90 "$days" --arg collected_at "$collected_at" \
    "$lib"'
     card_yaml($merged30;  $merged90;  $merged180;  $merged360;
               $openpr30;  $openpr90;  $openpr180;  $openpr360;
               $closei30;  $closei90;  $closei180;  $closei360;
               $openi30;   $openi90;   $openi180;   $openi360;
               $commit30;  $commit90;  $commit180;  $commit360;
               $date30;    $date90;    $date180;    $date360;
               $days90;    $collected_at)'
