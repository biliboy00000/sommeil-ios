# -*- coding: utf-8 -*-
"""
Suivi du sommeil v2 - réception des séances envoyées par l'app iPhone « Sommeil ».

Double-clique sur 5_RECEVOIR_IPHONE.bat : l'adresse à recopier dans l'app (Réglages)
s'affiche. Laisse la fenêtre ouverte ; le matin, l'app envoie la nuit toute seule
(ou avec le bouton « Envoyer au PC »).

Les séances arrivent dans le dossier « iphone_v2 », une séance par sous-dossier.
Un envoi coupé reprend où il s'était arrêté. Chaque séance reçue est vérifiée
(verification.txt dans son dossier).

Ce programme n'utilise que Python lui-même ; la vérification utilise numpy et scipy
(installés par 1_INSTALLER.bat).
"""
import os
import re
import sys
import json
import time
import queue
import socket
import datetime
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

DOSSIER = os.path.dirname(os.path.abspath(__file__))
DOSSIER_V2 = os.path.join(DOSSIER, "iphone_v2")
PORTS = (8010, 8011, 8012)
ID_VALIDE = re.compile(r"^[A-Za-z0-9_\-]{3,80}$")
MORCEAU_VALIDE = re.compile(r"^[A-Za-z0-9_\-][A-Za-z0-9_.\-]{0,80}$")


def ip_locale():
    for cible in (("8.8.8.8", 80), ("192.168.1.1", 80)):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(cible)
            ip = s.getsockname()[0]
            s.close()
            if not ip.startswith("127."):
                return ip
        except OSError:
            continue
    try:
        return socket.gethostbyname(socket.gethostname())
    except OSError:
        return "127.0.0.1"


def chemin_sur(id_seance, morceaux):
    """Chemin d'un fichier dans la séance, en refusant tout ce qui sortirait du dossier."""
    if not ID_VALIDE.match(id_seance):
        return None
    if not morceaux or any(not MORCEAU_VALIDE.match(m) or m in (".", "..") for m in morceaux):
        return None
    base = os.path.realpath(os.path.join(DOSSIER_V2, id_seance))
    chemin = os.path.realpath(os.path.join(base, *morceaux))
    if not chemin.startswith(base + os.sep):
        return None
    return chemin


def fichiers_recus(id_seance):
    base = os.path.join(DOSSIER_V2, id_seance)
    res = {}
    if not os.path.isdir(base):
        return res
    for racine, _, noms in os.walk(base):
        for nom in noms:
            if nom.endswith(".part"):
                continue
            chemin = os.path.join(racine, nom)
            rel = os.path.relpath(chemin, base).replace(os.sep, "/")
            res[rel] = os.path.getsize(chemin)
    return res


def ecrire_json(chemin, donnees):
    tmp = chemin + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(donnees, f, indent=2, ensure_ascii=False)
    os.replace(tmp, chemin)


PAGE = """<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Récepteur Sommeil</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:520px;margin:30px auto;padding:0 18px;
color:#1f2733;line-height:1.5}code{background:#eef1f5;padding:2px 6px;border-radius:6px}</style></head><body>
<h1>Le PC est prêt ✅</h1>
<p>Dans l'app <b>Sommeil</b> : Réglages (roue dentée) › Adresse du PC, écris <code>%s</code>,
puis « Tester la connexion ».</p></body></html>"""


def creer_serveur(file_recues, infos):
    class Recepteur(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def _json(self, code, donnees):
            corps = json.dumps(donnees, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(corps)))
            self.end_headers()
            self.wfile.write(corps)

        def _morceaux(self):
            chemin = self.path.split("?", 1)[0]
            from urllib.parse import unquote
            return [unquote(m) for m in chemin.strip("/").split("/") if m]

        def do_GET(self):
            m = self._morceaux()
            if not m:
                corps = (PAGE % infos.get("adresse", "?")).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(corps)))
                self.end_headers()
                self.wfile.write(corps)
            elif m == ["v2", "ping"]:
                self._json(200, {"ok": True, "machine": socket.gethostname(), "version": 2})
            elif len(m) == 3 and m[:2] == ["v2", "seance"] and ID_VALIDE.match(m[2]):
                self._json(200, {"ok": True, "fichiers": fichiers_recus(m[2])})
            else:
                self._json(404, {"ok": False, "message": "adresse inconnue"})

        def do_PUT(self):
            m = self._morceaux()
            if len(m) < 4 or m[:2] != ["v2", "seance"]:
                return self._json(404, {"ok": False, "message": "adresse inconnue"})
            cible = chemin_sur(m[2], m[3:])
            if cible is None:
                return self._json(400, {"ok": False, "message": "nom de fichier refusé"})
            taille = int(self.headers.get("Content-Length", "0") or 0)
            os.makedirs(os.path.dirname(cible), exist_ok=True)
            recu = 0
            try:
                with open(cible + ".part", "wb") as f:
                    while recu < taille:
                        bloc = self.rfile.read(min(1 << 20, taille - recu))
                        if not bloc:
                            break
                        f.write(bloc)
                        recu += len(bloc)
            except OSError as e:
                return self._json(500, {"ok": False, "message": "écriture impossible : %s" % e})
            if recu != taille:
                try:
                    os.remove(cible + ".part")
                except OSError:
                    pass
                return self._json(400, {"ok": False, "message": "fichier incomplet"})
            os.replace(cible + ".part", cible)
            afficher("  reçu %-48s %8.1f Mo" % ("/".join(m[2:])[-48:], taille / 1e6))
            self._json(200, {"ok": True, "taille": taille})

        def do_POST(self):
            m = self._morceaux()
            if len(m) != 4 or m[:2] != ["v2", "seance"] or m[3] != "fin" or not ID_VALIDE.match(m[2]):
                return self._json(404, {"ok": False, "message": "adresse inconnue"})
            taille = int(self.headers.get("Content-Length", "0") or 0)
            try:
                attendu = json.loads(self.rfile.read(taille).decode("utf-8")).get("fichiers", {})
            except ValueError:
                return self._json(400, {"ok": False, "message": "liste de fichiers illisible"})
            recus = fichiers_recus(m[2])
            manquants = [n for n, t in attendu.items() if recus.get(n) != t]
            if manquants:
                return self._json(400, {"ok": False,
                                        "message": "%d fichier(s) manquant(s) ou incomplet(s) : renvoie la séance."
                                        % len(manquants)})
            dossier = os.path.join(DOSSIER_V2, m[2])
            ecrire_json(os.path.join(dossier, "recu.json"),
                        {"recu_le": datetime.datetime.now().isoformat(timespec="seconds"),
                         "fichiers": len(attendu), "octets": sum(attendu.values())})
            self._json(200, {"ok": True, "message": "Reçu en entier sur %s." % socket.gethostname()})
            file_recues.put(dossier)

    for port in PORTS:
        try:
            serveur = ThreadingHTTPServer(("0.0.0.0", port), Recepteur)
            serveur.daemon_threads = True
            return serveur, port
        except OSError:
            continue
    return None, None


_verrou = threading.Lock()


def afficher(texte):
    with _verrou:
        print(texte)
        sys.stdout.flush()


def duree_txt(s):
    s = int(round(s))
    return "%d h %02d" % (s // 3600, s // 60 % 60) if s >= 3600 else "%d min %02d s" % (s // 60, s % 60)


def presenter(dossier):
    """Affiche le bilan d'une séance reçue, puis lance la vérification détaillée."""
    afficher("")
    afficher("=" * 68)
    afficher("  Séance reçue : %s" % os.path.basename(dossier))
    afficher("=" * 68)
    try:
        with open(os.path.join(dossier, "resume.json"), encoding="utf-8") as f:
            r = json.load(f)
        debut = datetime.datetime.fromtimestamp(r["startUnix"]).strftime("%d/%m %H:%M")
        fin = datetime.datetime.fromtimestamp(r["endUnix"]).strftime("%H:%M")
        afficher("  Du %s à %s (%s)" % (debut, fin, duree_txt(r["duration"])))
        afficher("  %s" % r["endExplanation"])
        afficher("  Capteurs enregistrés : %.0f %% du temps · son : %.0f %%"
                 % (100 * r["sensorCoverage"], 100 * r["audioCoverage"]))
        for perte in r.get("losses", [])[:10]:
            heure = datetime.datetime.fromtimestamp(perte["startUnix"]).strftime("%H:%M:%S")
            afficher("  - perdu à %s pendant %s (%s) : %s" % (heure, duree_txt(perte["duration"]),
                                                             perte["what"], perte["cause"]))
    except (OSError, ValueError, KeyError):
        afficher("  (pas de bilan resume.json)")
    try:
        import verifier_seance
    except ImportError:
        afficher("\n  Vérification détaillée impossible : lance 1_INSTALLER.bat pour installer numpy et scipy.")
        return
    afficher("\n  Vérification détaillée en cours (quelques secondes à quelques minutes)...")
    try:
        rapport = verifier_seance.verifier(dossier)
        texte = rapport.texte()
        with open(os.path.join(dossier, "verification.txt"), "w", encoding="utf-8") as f:
            f.write(texte)
        with open(os.path.join(dossier, "verification.json"), "w", encoding="utf-8") as f:
            json.dump(rapport.resultats, f, indent=2, ensure_ascii=False)
        afficher("")
        afficher(texte)
        afficher("  (enregistré dans %s)" % os.path.join(os.path.basename(DOSSIER_V2), os.path.basename(dossier),
                                                         "verification.txt"))
    except Exception as e:  # la vérification ne doit jamais empêcher de recevoir
        import traceback
        traceback.print_exc()
        afficher("  Vérification impossible : %s" % e)


def main():
    print("=" * 68)
    print("  SUIVI DU SOMMEIL v2 - réception des nuits de l'app iPhone « Sommeil »")
    print("=" * 68)
    if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]):     # vérifier un dossier déjà reçu
        presenter(os.path.abspath(sys.argv[1]))
        return
    os.makedirs(DOSSIER_V2, exist_ok=True)
    file_recues = queue.Queue()
    ip = ip_locale()
    infos = {}
    serveur, port = creer_serveur(file_recues, infos)
    if serveur is None:
        print("\n  Impossible d'ouvrir la réception (ports %s occupés). Ferme les autres fenêtres"
              % ", ".join(map(str, PORTS)))
        print("  du suivi du sommeil et relance.")
        return
    adresse = "%s:%d" % (ip, port)
    infos["adresse"] = adresse
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    print("\n  Adresse à recopier dans l'app Sommeil (Réglages › Adresse du PC) :\n")
    print("        %s\n" % adresse)
    print("  L'iPhone doit être sur le même Wi-Fi que ce PC. La première fois, Windows demande")
    print("  d'autoriser Python sur le réseau : coche « Réseaux privés ».")
    print("  Les séances arrivent dans le dossier « iphone_v2 ».")
    print("\n  En attente... (laisse cette fenêtre ouverte ; Entrée pour quitter)")
    arret = threading.Event()

    def entree():
        try:
            input()
        except EOFError:
            return
        arret.set()

    threading.Thread(target=entree, daemon=True).start()
    while not arret.is_set():
        try:
            dossier = file_recues.get(timeout=0.5)
        except queue.Empty:
            continue
        presenter(dossier)
        afficher("\n  En attente d'une autre séance... (Entrée pour quitter)")
    serveur.shutdown()


if __name__ == "__main__":
    main()
