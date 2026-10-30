#!/bin/bash
# Ajoute à une source SideStore les apps du dépôt qui y manquent, d'après leur dernière version
# publiée (Sommeil : versions « v0.* », Ciné : versions « cine-v* »). La source se répare ainsi
# toute seule si une publication a perdu une app.
#
#     scripts/completer_source.sh base.json
set -euo pipefail
BASE="$1"
DEPOT="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY manquant}"
ICI=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)

present() {
  python3 -c 'import json, sys
apps = json.load(open(sys.argv[1])).get("apps", [])
sys.exit(0 if any(a.get("bundleIdentifier") == sys.argv[2] for a in apps) else 1)' "$BASE" "$1"
}

ajouter() {
  local identifiant=$1 prefixe=$2 ipa=$3 app=$4
  if present "$identifiant"; then return 0; fi
  local tag id
  tag=$(gh api "repos/$DEPOT/releases?per_page=50" \
    -q "[.[] | select(.draft | not) | select(.tag_name | startswith(\"$prefixe\")) | select(any(.assets[]; .name == \"$ipa\"))][0].tag_name // empty")
  if [ -z "$tag" ]; then
    echo "$app : aucune version publiée, pas dans la source." >&2
    return 0
  fi
  id=$(gh api "repos/$DEPOT/releases/tags/$tag" -q ".assets[] | select(.name == \"$ipa\") | .id")
  gh api -H "Accept: application/octet-stream" "repos/$DEPOT/releases/assets/$id" > "$TMP/$ipa"
  (cd "$TMP" && unzip -q -o "$ipa" "Payload/$app.app/Info.plist")
  python3 "$ICI/source_sidestore.py" "$TMP/Payload/$app.app" "$TMP/$ipa" "$tag" "$BASE.complet" --base "$BASE" >&2
  mv "$BASE.complet" "$BASE"
  echo "$app remise dans la source (version $tag)." >&2
}

ajouter com.suivisommeil.enregistreur "v0." Sommeil.ipa Sommeil
ajouter com.cine.pellicule "cine-v" Cine.ipa Cine
