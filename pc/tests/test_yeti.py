# -*- coding: utf-8 -*-
"""Tests de l'enregistrement du Yeti commandé par l'app, avec un micro simulé (pas de vrai micro ici)."""
import os
import sys
import json
import time
import queue
import shutil
import tempfile
import threading
import unittest
import http.client

import numpy as np

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(ICI))

try:
    import soundfile  # noqa: F401
    import soxr  # noqa: F401
    AUDIO = True
except ImportError:
    AUDIO = False

import yeti  # noqa: E402
import recevoir_iphone  # noqa: E402


class MicroSimule:
    """Produit un « la » à 440 Hz en stéréo 48 kHz, 10 fois plus vite que le temps réel."""

    def __init__(self, rappel):
        self.rappel = rappel
        self.nom = "Microphone (Yeti Stereo Microphone) — simulé"
        self.freq = 48000
        self.yeti = True
        self.arret = threading.Event()
        self.envoyes = 0

    def demarrer(self):
        def boucle():
            while not self.arret.is_set():
                n = 4800
                k = np.arange(n) + self.envoyes
                x = (0.1 * np.sin(2 * np.pi * 440 * k / 48000)).astype(np.float32)
                self.rappel(time.time(), np.stack([x, x], axis=1), 48000)
                self.envoyes += n
                time.sleep(0.01)
        self.fil = threading.Thread(target=boucle, daemon=True)
        self.fil.start()

    def arreter(self):
        self.arret.set()
        self.fil.join()


class MicroAbsent:
    def __init__(self, rappel):
        pass

    def demarrer(self):
        raise RuntimeError("aucun micro utilisable (test)")

    def arreter(self):
        pass


@unittest.skipUnless(AUDIO, "soundfile / soxr absents")
class TestsEnregistreur(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.ancien = yeti.MINUTES_PAR_FICHIER
        yeti.MINUTES_PAR_FICHIER = 0.05          # fichiers de 3 s pour tester le découpage

    def tearDown(self):
        yeti.MINUTES_PAR_FICHIER = self.ancien
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_enregistre_decoupe_et_ferme(self):
        import soundfile as sf
        journal = []
        e = yeti.EnregistreurYeti(fabrique_source=MicroSimule, journal=journal.append)
        dossier = os.path.join(self.tmp, "seance_test")
        etat = e.demarrer(dossier, "seance_test", heure_iphone=time.time() - 0.5)
        self.assertTrue(etat["enregistre"])
        self.assertTrue(etat["yeti"])
        limite = time.time() + 30                 # on attend ≈ 10 s de son simulé (3 fichiers de 3 s)
        while e.etat()["secondes"] < 10 and time.time() < limite:
            time.sleep(0.1)
        self.assertGreaterEqual(e.etat()["secondes"], 10)
        etat = e.arreter("seance_test")
        self.assertFalse(etat["enregistre"])
        lignes = [json.loads(l) for l in open(os.path.join(dossier, "yeti", "index.jsonl"))]
        complets = [l for l in lignes if l["complete"]]
        self.assertGreaterEqual(len(complets), 3)
        total = 0
        for l in complets:
            x, fs = sf.read(os.path.join(dossier, l["file"]))
            self.assertEqual(fs, 16000)
            self.assertEqual(len(x), l["frames"])
            total += len(x)
            self.assertAlmostEqual(float(np.sqrt(np.mean(x ** 2))), 0.1 / np.sqrt(2), delta=0.01)
        self.assertGreater(total, 16000 * 5)
        horloge = [json.loads(l) for l in open(os.path.join(dossier, "yeti", "horloge.jsonl"))]
        self.assertAlmostEqual(horloge[0]["pc_moins_iphone_s"], 0.5, delta=0.2)
        evenements = [json.loads(l)["type"] for l in open(os.path.join(dossier, "yeti", "evenements.jsonl"))]
        self.assertEqual(evenements, ["debut", "fin"])

    def test_double_demarrage_et_arret_de_securite(self):
        e = yeti.EnregistreurYeti(fabrique_source=MicroSimule, journal=lambda *_: None, duree_max=0.5)
        dossier = os.path.join(self.tmp, "seance_a")
        e.demarrer(dossier, "seance_a")
        e.demarrer(dossier, "seance_a")          # même séance : rien ne change
        self.assertEqual(e.etat()["seance"], "seance_a")
        time.sleep(1.2)                          # l'arrêt de sécurité doit avoir eu lieu
        self.assertFalse(e.etat()["enregistre"])
        self.assertEqual(e.etat()["derniere"]["raison"], "durée maximale atteinte")

    def test_micro_absent(self):
        e = yeti.EnregistreurYeti(fabrique_source=MicroAbsent, journal=lambda *_: None)
        etat = e.demarrer(os.path.join(self.tmp, "s"), "s")
        self.assertFalse(etat["enregistre"])
        self.assertIn("aucun micro", etat["erreur"])


@unittest.skipUnless(AUDIO, "soundfile / soxr absents")
class TestsCommandesHTTP(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.ancien = recevoir_iphone.DOSSIER_V2
        recevoir_iphone.DOSSIER_V2 = os.path.join(self.tmp, "iphone_v2")
        os.makedirs(recevoir_iphone.DOSSIER_V2)
        self.enregistreur = yeti.EnregistreurYeti(fabrique_source=MicroSimule, journal=lambda *_: None)
        self.recues = queue.Queue()
        self.serveur, self.port = recevoir_iphone.creer_serveur(self.recues, {"adresse": "test"},
                                                                self.enregistreur, "123456")
        threading.Thread(target=self.serveur.serve_forever, daemon=True).start()

    def tearDown(self):
        self.enregistreur.arreter(raison="fin du test")
        self.serveur.shutdown()
        self.serveur.server_close()
        recevoir_iphone.DOSSIER_V2 = self.ancien
        shutil.rmtree(self.tmp, ignore_errors=True)

    def requete(self, methode, chemin, corps=None, code="123456"):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        entetes = {"X-Unix": str(time.time())}
        if code is not None:
            entetes["X-Code-PC"] = code
        donnees = json.dumps(corps).encode() if corps is not None else None
        if donnees is not None:
            entetes["Content-Type"] = "application/json"
        c.request(methode, chemin, body=donnees, headers=entetes)
        r = c.getresponse()
        reponse = json.loads(r.read() or b"{}")
        c.close()
        return r.status, reponse

    def test_code_obligatoire(self):
        self.assertEqual(self.requete("GET", "/v2/yeti/etat", code=None)[0], 403)
        self.assertEqual(self.requete("POST", "/v2/yeti/demarrer", {"seance": "abc_123"}, code="000000")[0], 403)
        self.assertFalse(self.enregistreur.etat()["enregistre"])
        statut, ping = self.requete("GET", "/v2/ping", code=None)
        self.assertEqual(statut, 200)
        self.assertTrue(ping["yeti"])

    def test_demarrer_puis_arret_a_la_reception_de_la_seance(self):
        statut, etat = self.requete("POST", "/v2/yeti/demarrer", {"seance": "2026-10-11_23h00m00"})
        self.assertEqual(statut, 200)
        self.assertTrue(etat["enregistre"])
        # Attendre que du son soit écrit (la machine de compilation peut être lente).
        limite = time.time() + 10
        while True:
            time.sleep(0.25)
            statut, etat = self.requete("GET", "/v2/yeti/etat")
            if etat.get("secondes", 0) > 1 or time.time() > limite:
                break
        self.assertTrue(etat["enregistre"])
        self.assertGreater(etat["secondes"], 1)
        self.assertIsNotNone(etat["niveau_db"])
        # L'app envoie sa séance : la fin de l'envoi arrête le Yeti.
        statut, _ = self.requete("POST", "/v2/seance/2026-10-11_23h00m00/fin", {"fichiers": {}})
        self.assertEqual(statut, 200)
        self.assertFalse(self.enregistreur.etat()["enregistre"])
        dossier = os.path.join(recevoir_iphone.DOSSIER_V2, "2026-10-11_23h00m00", "yeti")
        self.assertTrue(any(n.endswith(".flac") for n in os.listdir(dossier)))

    def test_seance_invalide_refusee(self):
        statut, _ = self.requete("POST", "/v2/yeti/demarrer", {"seance": "../../evil"})
        self.assertEqual(statut, 400)
        self.assertFalse(self.enregistreur.etat()["enregistre"])

    def test_arreter_explicitement(self):
        self.requete("POST", "/v2/yeti/demarrer", {"seance": "s_123"})
        statut, etat = self.requete("POST", "/v2/yeti/arreter", {"seance": "s_123"})
        self.assertEqual(statut, 200)
        self.assertFalse(etat["enregistre"])


SIMULATEUR = os.environ.get("SIMULATEUR")


@unittest.skipUnless(AUDIO and SIMULATEUR and os.path.exists(SIMULATEUR or ""), "simulateur ou audio absent")
class TestsVerificationAvecYeti(unittest.TestCase):
    def test_section_yeti(self):
        import subprocess
        import verifier_seance
        tmp = tempfile.mkdtemp()
        try:
            dossier = os.path.join(tmp, "2026-10-11_23h00m00")
            subprocess.run([SIMULATEUR, dossier, "120", "60", "2"], check=True, capture_output=True)
            ancien = yeti.MINUTES_PAR_FICHIER
            yeti.MINUTES_PAR_FICHIER = 0.05
            try:
                e = yeti.EnregistreurYeti(fabrique_source=MicroSimule, journal=lambda *_: None)
                e.demarrer(dossier, "2026-10-11_23h00m00", heure_iphone=time.time() - 2.0)
                limite = time.time() + 30
                while e.etat()["secondes"] < 7 and time.time() < limite:
                    time.sleep(0.1)
                e.arreter()
            finally:
                yeti.MINUTES_PAR_FICHIER = ancien
            r = verifier_seance.verifier(dossier)
            self.assertIn("yeti", r.resultats)
            self.assertGreaterEqual(r.resultats["yeti"]["secondes"], 6)
            self.assertAlmostEqual(r.resultats["yeti"]["decalage_pc_s"], 2.0, delta=0.3)
            self.assertIn("Blue Yeti", r.texte())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestsCode(unittest.TestCase):
    def test_code_stable(self):
        tmp = tempfile.mkdtemp()
        ancien = recevoir_iphone.FICHIER_CODE
        recevoir_iphone.FICHIER_CODE = os.path.join(tmp, "code_app.txt")
        try:
            a = recevoir_iphone.lire_ou_creer_code()
            b = recevoir_iphone.lire_ou_creer_code()
            self.assertEqual(a, b)
            self.assertRegex(a, r"^\d{6}$")
        finally:
            recevoir_iphone.FICHIER_CODE = ancien
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
