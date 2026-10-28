# -*- coding: utf-8 -*-
"""
Écrit la « source » SideStore de l'app (format des sources AltStore), pour que SideStore
propose les mises à jour de Sommeil tout seul.

    python3 scripts/source_sidestore.py <Sommeil.app> <Sommeil.ipa> <tag> <sortie.json>

Utilisé par la compilation automatique de GitHub, qui publie source.json avec chaque version.
Lien à ajouter dans SideStore (onglet Sources, « + ») :
    https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json
"""
import datetime
import json
import os
import plistlib
import sys

DEPOT = "biliboy00000/sommeil-ios"
ICONE = "https://raw.githubusercontent.com/%s/main/App/Resources/Assets.xcassets/AppIcon.appiconset/icon.png" % DEPOT


def construire(app, ipa, tag, sortie):
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    # Les textes d'autorisation doivent correspondre exactement à ceux de l'app.
    confidentialite = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}
    version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info["CFBundleVersion"],
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": "Version compilée automatiquement (%s)." % tag,
        "downloadURL": "https://github.com/%s/releases/download/%s/Sommeil.ipa" % (DEPOT, tag),
        "size": os.path.getsize(ipa),
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    source = {
        "name": "Sommeil",
        "identifier": "com.suivisommeil.source",
        "subtitle": "Enregistreur de nuit pour iPhone",
        "iconURL": ICONE,
        "tintColor": "#4B3FBF",
        "nsfw": False,
        "apps": [{
            "name": "Sommeil",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Projet personnel",
            "subtitle": "Nuit, cœur et respiration, sur l'iPhone seul",
            "localizedDescription": (
                "Enregistre la nuit avec les capteurs de mouvement (100 mesures par seconde) et le micro, "
                "écran verrouillé, et montre les battements du cœur en direct. Pas un appareil médical."),
            "iconURL": ICONE,
            "tintColor": "#4B3FBF",
            "category": "lifestyle",
            "versions": [version],
            "appPermissions": {"entitlements": [], "privacy": confidentialite},
        }],
        "news": [],
    }
    with open(sortie, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
    print("Source écrite : %s (version %s, build %s)" % (sortie, version["version"], version["buildVersion"]))


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    construire(*sys.argv[1:])
