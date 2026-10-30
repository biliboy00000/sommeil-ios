# -*- coding: utf-8 -*-
"""
Écrit la « source » SideStore (format des sources AltStore) de ce dépôt, pour que SideStore
propose tout seul les mises à jour des apps : Sommeil et Ciné.

    python3 scripts/source_sidestore.py <App.app> <App.ipa> <tag> <sortie.json> [--base <source.json>]

L'app est reconnue par son identifiant (Info.plist). Avec --base, les autres apps de la source
existante sont gardées : chaque compilation (Sommeil ou Ciné) ne remplace que sa propre entrée.

Utilisé par la compilation automatique de GitHub, qui publie source.json avec la dernière version
de Sommeil (« latest »). Lien à ajouter dans SideStore (onglet Sources, « + ») :
    https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json
"""
import datetime
import json
import os
import plistlib
import sys

DEPOT = "biliboy00000/sommeil-ios"
BRUT = "https://raw.githubusercontent.com/%s/main/" % DEPOT

APPS = {
    "com.suivisommeil.enregistreur": {
        "name": "Sommeil",
        "subtitle": "Nuit, cœur et respiration, sur l'iPhone seul",
        "localizedDescription": (
            "Enregistre la nuit avec les capteurs de mouvement (100 mesures par seconde) et le micro, "
            "écran verrouillé, et montre les battements du cœur en direct. Pas un appareil médical."),
        "iconURL": BRUT + "App/Resources/Assets.xcassets/AppIcon.appiconset/icon.png",
        "tintColor": "#4B3FBF",
        "category": "lifestyle",
        "ipa": "Sommeil.ipa",
    },
    "com.cine.pellicule": {
        "name": "Ciné",
        "subtitle": "Photos RAW au rendu pellicule cinéma",
        "localizedDescription": (
            "Appareil photo qui récupère les données brutes du capteur, sans le traitement d'iOS "
            "(Smart HDR, Deep Fusion, netteté), et les développe avec un rendu pellicule cinéma : "
            "couleurs douces, peaux chaudes, noirs laiteux, hautes lumières qui s'arrondissent, "
            "halation et grain fin. Aperçu du rendu en direct, réglages manuels, formats jusqu'au 2,39:1."),
        "iconURL": BRUT + "Cine/App/Resources/Assets.xcassets/AppIcon.appiconset/icon.png",
        "tintColor": "#E8A04A",
        "category": "photo-video",
        "ipa": "Cine.ipa",
    },
}
ORDRE = list(APPS)


def entree(app, ipa, tag):
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    identifiant = info["CFBundleIdentifier"]
    if identifiant not in APPS:
        raise SystemExit("App inconnue : %s" % identifiant)
    meta = APPS[identifiant]
    # Les textes d'autorisation doivent correspondre exactement à ceux de l'app.
    confidentialite = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}
    version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info["CFBundleVersion"],
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": "Version compilée automatiquement (%s)." % tag,
        "downloadURL": "https://github.com/%s/releases/download/%s/%s" % (DEPOT, tag, meta["ipa"]),
        "size": os.path.getsize(ipa),
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    return {
        "name": meta["name"],
        "bundleIdentifier": identifiant,
        "developerName": "Projet personnel",
        "subtitle": meta["subtitle"],
        "localizedDescription": meta["localizedDescription"],
        "iconURL": meta["iconURL"],
        "tintColor": meta["tintColor"],
        "category": meta["category"],
        "versions": [version],
        "appPermissions": {"entitlements": [], "privacy": confidentialite},
    }


def lire_base(chemin):
    if not chemin or not os.path.exists(chemin):
        return []
    try:
        with open(chemin, encoding="utf-8") as f:
            apps = json.load(f).get("apps", [])
        return [a for a in apps if isinstance(a, dict) and a.get("bundleIdentifier") in APPS]
    except (ValueError, OSError, AttributeError):
        print("Source de base illisible : ignorée")
        return []


def construire(app, ipa, tag, sortie, base=None):
    nouvelle = entree(app, ipa, tag)
    apps = {a["bundleIdentifier"]: a for a in lire_base(base)}
    apps[nouvelle["bundleIdentifier"]] = nouvelle
    source = {
        "name": "Sommeil et Ciné",
        "identifier": "com.suivisommeil.source",
        "subtitle": "Apps personnelles pour iPhone",
        "iconURL": APPS["com.suivisommeil.enregistreur"]["iconURL"],
        "tintColor": "#4B3FBF",
        "nsfw": False,
        "apps": [apps[i] for i in ORDRE if i in apps],
        "news": [],
    }
    with open(sortie, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
    for a in source["apps"]:
        v = a["versions"][0]
        print("%s : version %s (build %s)" % (a["name"], v["version"], v["buildVersion"]))
    print("Source écrite : %s" % sortie)


if __name__ == "__main__":
    arguments = sys.argv[1:]
    base = None
    if "--base" in arguments:
        i = arguments.index("--base")
        base = arguments[i + 1] if i + 1 < len(arguments) else None
        del arguments[i:i + 2]
    if len(arguments) != 4:
        print(__doc__)
        sys.exit(1)
    construire(*arguments, base=base)
