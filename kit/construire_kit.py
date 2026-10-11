# -*- coding: utf-8 -*-
"""
Fabrique le paquet d'installation complet (app iPhone + fichiers du PC + mode d'emploi).

    python3 kit/construire_kit.py <Sommeil.ipa> <version> <sortie.zip>

Utilisé par la compilation automatique de GitHub, qui publie le paquet avec chaque version.
"""
import os
import sys
import zipfile
import datetime

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOSSIER = "SuiviSommeil"
FICHIERS_PC = ["1_INSTALLER.bat", "5_RECEVOIR_IPHONE.bat", "6_DEMARRAGE_AUTOMATIQUE.bat",
               "recevoir_iphone.py", "yeti.py", "lecture_iphone.py", "verifier_seance.py", "requirements.txt"]
INTERDITS = ("code_app.txt", "iphone_v2", ".venv")


def fins_de_ligne_windows(octets):
    texte = octets.replace(b"\r\n", b"\n")
    return texte.replace(b"\n", b"\r\n")


def construire(ipa, version, sortie):
    if not os.path.isfile(ipa):
        raise SystemExit("fichier introuvable : %s" % ipa)
    with open(os.path.join(RACINE, "kit", "LISEZ-MOI.txt"), "rb") as f:
        lisez_moi = f.read().decode("utf-8").replace("{VERSION}", "%s (%s)" % (
            version, datetime.date.today().strftime("%d/%m/%Y")))
    entrees = [("LISEZ-MOI.txt", fins_de_ligne_windows(lisez_moi.encode("utf-8")))]
    for nom in FICHIERS_PC:
        with open(os.path.join(RACINE, "pc", nom), "rb") as f:
            contenu = f.read()
        if nom.endswith((".bat", ".txt")):
            contenu = fins_de_ligne_windows(contenu)
        entrees.append((nom, contenu))
    with open(ipa, "rb") as f:
        entrees.append(("Sommeil.ipa", f.read()))
    for nom, _ in entrees:
        assert not any(i in nom for i in INTERDITS), nom
    with zipfile.ZipFile(sortie, "w", zipfile.ZIP_DEFLATED) as z:
        for nom, contenu in entrees:
            z.writestr("%s/%s" % (DOSSIER, nom), contenu)
    print("Paquet écrit : %s (%d fichiers, %.1f Mo)" % (sortie, len(entrees), os.path.getsize(sortie) / 1e6))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    construire(*sys.argv[1:])
