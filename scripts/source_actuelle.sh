#!/bin/bash
# Télécharge la source SideStore publiée dans la version marquée « latest » (celle de Sommeil),
# pour que chaque compilation garde l'entrée de l'autre app.
#
#     TAG=$(scripts/source_actuelle.sh base.json)
#
# Écrit la source dans le fichier donné et affiche le tag de la version sur la sortie standard.
# Utilise l'API REST de GitHub (GH_TOKEN). S'arrête avec une erreur si le téléchargement échoue :
# mieux vaut ne rien publier qu'une source où il manque une app.
set -euo pipefail
SORTIE="$1"
DEPOT="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY manquant}"

TAG=$(gh api "repos/$DEPOT/releases/latest" -q .tag_name 2>/dev/null || true)
if [ -z "$TAG" ]; then
  echo "Pas encore de version publiée : source vide." >&2
  echo '{}' > "$SORTIE"
  exit 0
fi
ID=$(gh api "repos/$DEPOT/releases/tags/$TAG" -q '.assets[] | select(.name=="source.json") | .id')
if [ -z "$ID" ]; then
  echo "Pas de source.json dans $TAG : source vide." >&2
  echo '{}' > "$SORTIE"
else
  gh api -H "Accept: application/octet-stream" "repos/$DEPOT/releases/assets/$ID" > "$SORTIE"
fi
python3 - "$SORTIE" "$TAG" >&2 <<'PY'
import json, sys
apps = json.load(open(sys.argv[1])).get("apps", [])
print("Source actuelle (%s) : %s" % (sys.argv[2], ", ".join(
    "%s %s" % (a.get("name"), a.get("versions", [{}])[0].get("version")) for a in apps) or "aucune app"))
PY
echo "$TAG"
