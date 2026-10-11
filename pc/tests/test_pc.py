# -*- coding: utf-8 -*-
"""
Tests du côté PC, sur une séance simulée écrite par le simulateur Swift (même code que l'app).

    SIMULATEUR=<chemin de SessionSimulator> python -m unittest discover -s pc/tests -v
"""
import os
import sys
import json
import queue
import shutil
import tempfile
import threading
import unittest
import subprocess
import http.client

import numpy as np

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(ICI))

import lecture_iphone  # noqa: E402
import recevoir_iphone  # noqa: E402
import verifier_seance  # noqa: E402

SIMULATEUR = os.environ.get("SIMULATEUR")


def creer_seance(dossier, duree=600, pouls=62, graine=1):
    subprocess.run([SIMULATEUR, dossier, str(duree), str(pouls), str(graine)], check=True, capture_output=True)


def ajouter_son(dossier, echantillons=4096 * 12):
    """Ajoute deux fichiers son ALAC/CAF comme ceux de l'app (si PyAV sait les écrire)."""
    import av
    os.makedirs(os.path.join(dossier, "audio"), exist_ok=True)
    index = []
    for k in range(2):
        nom = "audio/a_%05d.caf" % k
        with av.open(os.path.join(dossier, nom), "w", format="caf") as sortie:
            flux = sortie.add_stream("alac", rate=16000)
            flux.layout = "mono"
            t = np.arange(echantillons) / 16000
            x = (0.1 * np.sin(2 * np.pi * 220 * t) * 32767).astype(np.int16)
            for debut_trame in range(0, len(x), 4096):     # trames de la taille attendue par l'encodeur
                morceau = x[debut_trame:debut_trame + 4096].reshape(1, -1)
                trame = av.AudioFrame.from_ndarray(np.ascontiguousarray(morceau), format="s16p", layout="mono")
                trame.rate = 16000
                trame.pts = debut_trame
                for paquet in flux.encode(trame):
                    sortie.mux(paquet)
            for paquet in flux.encode(None):
                sortie.mux(paquet)
        debut = 50000 + 60 * k
        index.append({"file": nom, "startUptime": debut, "startUnix": 1760120000 + 60 * k,
                      "frames": 0, "sampleRate": 16000, "complete": False})
        index.append({"file": nom, "startUptime": debut, "startUnix": 1760120000 + 60 * k,
                      "frames": echantillons, "sampleRate": 16000, "complete": True})
    with open(os.path.join(dossier, "audio", "index.jsonl"), "w") as f:
        for ligne in index:
            f.write(json.dumps(ligne) + "\n")


@unittest.skipUnless(SIMULATEUR and os.path.exists(SIMULATEUR), "simulateur Swift absent (variable SIMULATEUR)")
class TestsSeance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.dossier = os.path.join(cls.tmp, "2026-10-10_22h00m00_test")
        creer_seance(cls.dossier)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_lecture(self):
        s = lecture_iphone.Seance(self.dossier)
        t, v = s.flux("dm")
        self.assertEqual(len(t), 60000)
        self.assertEqual(v.shape, (60000, 13))
        self.assertAlmostEqual(1 / np.median(np.diff(t)), 100, delta=0.5)
        unix = s.vers_unix(t[:1])
        self.assertAlmostEqual(float(unix[0]), s.info["startUnix"], delta=0.01)
        self.assertEqual([m[1] for m in s.marqueurs()][:2], ["debut_dos", "calibration_fin"])
        for prefixe in ("acc", "gyr"):
            self.assertEqual(len(s.flux(prefixe)[0]), 60000)

    def test_fichier_coupe(self):
        source = lecture_iphone.Seance(self.dossier).fichiers_flux("acc")[0]
        copie = os.path.join(self.tmp, "coupe.bin")
        with open(source, "rb") as f:
            octets = f.read()
        with open(copie, "wb") as f:
            f.write(octets[:-7])
        _, t, _ = lecture_iphone.lire_fichier(copie)
        self.assertEqual(len(t), 59999)

    def test_verification_retrouve_la_verite(self):
        r = verifier_seance.verifier(self.dossier).resultats
        self.assertAlmostEqual(r["flux"]["dm"]["frequence_hz"], 100, delta=0.5)
        self.assertEqual(r["flux"]["dm"]["trous"], 0)
        self.assertAlmostEqual(r["pouls"]["bpm_median"], r["pouls"]["bpm_vrai"], delta=1.5)
        self.assertGreater(max(r["pouls"]["qualite_combinee"], r["pouls"]["qualite_meilleure_voie"]), 0.5)
        dos = r["respiration"][0]
        self.assertAlmostEqual(dos["gravite"]["par_minute"], 14, delta=0.7)
        cote = [x for x in r["respiration"] if x["passage"].startswith("côté")]
        self.assertTrue(all(x["gyroscope"]["qualite"] > 0.5 for x in cote))
        self.assertEqual(len(r["apnees"]), 2)
        self.assertTrue(all(a["visible"] for a in r["apnees"]))

    def test_debut_differe_et_calibration_automatique(self):
        dossier = os.path.join(self.tmp, "differe")
        shutil.copytree(self.dossier, dossier)
        chemin = os.path.join(dossier, "session.json")
        with open(chemin, encoding="utf-8") as f:
            info = json.load(f)
        info["kind"] = "nuit"
        info["delayedStart"] = {"requestedUnix": info["startUnix"] - 45 * 60, "delayMinutes": 45, "source": "notification"}
        info["calibrationMode"] = "automatique"
        # Meilleure tranche gardée : à plat mais écran vers le matelas (pas « sur le dos »).
        info["calibration"]["gravity"] = [0.0, 0.1, 0.995]
        with open(chemin, "w", encoding="utf-8") as f:
            json.dump(info, f)
        rapport = verifier_seance.verifier(dossier)
        texte = rapport.texte()
        self.assertIn("Début différé", texte)
        self.assertIn("45 min plus tard", texte)
        self.assertIn("Calibration automatique", texte)
        self.assertIn("aucun moment calme sur le dos trouvé", texte)
        self.assertEqual(rapport.resultats["debut_differe"]["delayMinutes"], 45)
        self.assertFalse(rapport.resultats["calibration"]["sur_le_dos"])
        # Repli sur l'orientation du téléphone : le début de la séance simulée (sur le dos) est bien « dos ».
        self.assertEqual(rapport.resultats["tenue"][0]["position"], "dos")

    def test_calibration_guidee_affichee(self):
        texte = verifier_seance.verifier(self.dossier).texte()
        self.assertIn("Calibration guidée", texte)
        self.assertNotIn("Début différé", texte)

    def test_son(self):
        try:
            import av  # noqa: F401
        except ImportError:
            self.skipTest("PyAV absent")
        dossier = os.path.join(self.tmp, "avec_son")
        shutil.copytree(self.dossier, dossier)
        ajouter_son(dossier)
        s = lecture_iphone.Seance(dossier)
        segments = s.segments_audio()
        self.assertEqual(len(segments), 2)
        x = s.lire_audio(segments[0])
        self.assertEqual(len(x), 4096 * 12)
        self.assertAlmostEqual(float(np.sqrt(np.mean(x ** 2))), 0.1 / np.sqrt(2), delta=0.005)


class TestsTenue(unittest.TestCase):
    """Le contrôle de tenue repère un téléphone qui glisse (battements qui disparaissent sans changement de position)."""

    def signaux(self, duree=1800, glisse_a=900, graine=4):
        rng = np.random.default_rng(graine)
        fs = 100
        n = duree * fs
        t = np.arange(n) / fs
        battements = np.cumsum(0.85 + 0.02 * rng.standard_normal(int(duree / 0.8)))
        coeur = np.zeros(n)
        for b in battements[battements < duree - 1]:
            i = int(b * fs)
            k = np.arange(15)
            coeur[i:i + 15] += np.exp(-k / 4) * np.sin(2 * np.pi * 13 * k / fs)
        gain = np.where(t < glisse_a, 1.0, 0.08)            # après le glissement, presque plus de signal
        bruit = lambda: 0.15 * rng.standard_normal(n)
        col = {"rx": 0.02 * (gain * coeur + bruit()), "ry": 0.01 * (gain * coeur + bruit()),
               "uz": 0.005 * (gain * coeur + bruit()),
               "ux": 0.0005 * rng.standard_normal(n), "uy": 0.0005 * rng.standard_normal(n),
               "gx": np.zeros(n), "gy": np.full(n, 0.1), "gz": np.full(n, -0.995)}
        return t, col

    def test_glissement_detecte(self):
        t, col = self.signaux()
        blocs = verifier_seance.tenue_telephone(t, col, [0.0, 0.1, -0.995], 300)
        self.assertEqual(len(blocs), 6)
        self.assertTrue(all(b["position"] == "dos" for b in blocs))
        self.assertGreater(blocs[0]["qualite"], 0.5)
        self.assertLess(blocs[4]["qualite"], 0.3)
        alertes = [i for i, b in enumerate(blocs) if b.get("alerte")]
        self.assertEqual(alertes, [3])

    def test_pas_d_alerte_si_tout_va_bien(self):
        t, col = self.signaux(glisse_a=10 ** 6)
        blocs = verifier_seance.tenue_telephone(t, col, [0.0, 0.1, -0.995], 300)
        self.assertFalse(any(b.get("alerte") for b in blocs))
        self.assertTrue(all(b["qualite"] > 0.5 for b in blocs))

    def test_positions(self):
        g0 = [0.0, 0.1, -0.995]
        self.assertEqual(verifier_seance.position([0.0, 0.1, -0.99], g0)[0], "dos")
        self.assertEqual(verifier_seance.position([0.97, 0.05, -0.2], g0)[0], "côté G")
        self.assertEqual(verifier_seance.position([-0.97, 0.05, -0.2], g0)[0], "côté D")
        self.assertEqual(verifier_seance.position([0.0, -0.1, 0.99], g0)[0], "ventre")


@unittest.skipUnless(SIMULATEUR and os.path.exists(SIMULATEUR), "simulateur Swift absent (variable SIMULATEUR)")
class TestsReception(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.source = os.path.join(self.tmp, "iphone", "2026-10-10_22h00m00_test")
        creer_seance(self.source, duree=120)
        self.ancien = recevoir_iphone.DOSSIER_V2
        recevoir_iphone.DOSSIER_V2 = os.path.join(self.tmp, "pc", "iphone_v2")
        os.makedirs(recevoir_iphone.DOSSIER_V2)
        self.recues = queue.Queue()
        self.serveur, self.port = recevoir_iphone.creer_serveur(self.recues, {"adresse": "test"})
        threading.Thread(target=self.serveur.serve_forever, daemon=True).start()

    def tearDown(self):
        self.serveur.shutdown()
        self.serveur.server_close()
        recevoir_iphone.DOSSIER_V2 = self.ancien
        shutil.rmtree(self.tmp, ignore_errors=True)

    def requete(self, methode, chemin, corps=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request(methode, chemin, body=corps)
        r = c.getresponse()
        donnees = r.read()
        c.close()
        return r.status, donnees

    def fichiers_locaux(self):
        res = {}
        for racine, _, noms in os.walk(self.source):
            for nom in noms:
                chemin = os.path.join(racine, nom)
                res[os.path.relpath(chemin, self.source).replace(os.sep, "/")] = chemin
        return res

    def test_envoi_complet_et_reprise(self):
        statut, corps = self.requete("GET", "/v2/ping")
        self.assertEqual(statut, 200)
        self.assertTrue(json.loads(corps)["ok"])
        ident = os.path.basename(self.source)
        locaux = self.fichiers_locaux()
        noms = sorted(locaux)
        # Envoi interrompu : la moitié des fichiers seulement.
        for nom in noms[: len(noms) // 2]:
            with open(locaux[nom], "rb") as f:
                statut, _ = self.requete("PUT", "/v2/seance/%s/%s" % (ident, nom), f.read())
            self.assertEqual(statut, 200)
        manifeste = json.dumps({"fichiers": {n: os.path.getsize(p) for n, p in locaux.items()}}).encode()
        statut, _ = self.requete("POST", "/v2/seance/%s/fin" % ident, manifeste)
        self.assertEqual(statut, 400)          # incomplet : refusé
        # Reprise : l'app demande ce que le PC a déjà, et envoie le reste.
        statut, corps = self.requete("GET", "/v2/seance/%s" % ident)
        deja = json.loads(corps)["fichiers"]
        self.assertEqual(len(deja), len(noms) // 2)
        for nom in noms:
            if deja.get(nom) == os.path.getsize(locaux[nom]):
                continue
            with open(locaux[nom], "rb") as f:
                statut, _ = self.requete("PUT", "/v2/seance/%s/%s" % (ident, nom), f.read())
            self.assertEqual(statut, 200)
        statut, _ = self.requete("POST", "/v2/seance/%s/fin" % ident, manifeste)
        self.assertEqual(statut, 200)
        arrive = self.recues.get(timeout=2)
        for nom, chemin in locaux.items():
            with open(chemin, "rb") as a, open(os.path.join(arrive, nom), "rb") as b:
                self.assertEqual(a.read(), b.read(), nom)
        self.assertTrue(os.path.exists(os.path.join(arrive, "recu.json")))

    def test_chemins_refuses(self):
        for chemin in ("/v2/seance/abc/..%2F..%2Fevil.txt", "/v2/seance/../x/y", "/v2/seance/ok_id/%2Fetc%2Fpasswd",
                       "/v2/seance/ok_id/a/../../b"):
            statut, _ = self.requete("PUT", chemin, b"x")
            self.assertIn(statut, (400, 404), chemin)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "pc", "evil.txt")))


if __name__ == "__main__":
    unittest.main()
