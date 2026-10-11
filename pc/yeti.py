# -*- coding: utf-8 -*-
"""
Enregistrement du Blue Yeti commandé par l'app iPhone (via recevoir_iphone.py).

Le son est écrit dans le dossier de la séance de l'iPhone :
    iphone_v2/<séance>/yeti/y_00000.flac, y_00001.flac…   (16 kHz, mono, 10 min par fichier)
    iphone_v2/<séance>/yeti/index.jsonl                    (début et durée de chaque fichier)
    iphone_v2/<séance>/yeti/horloge.jsonl                  (écart entre l'horloge du PC et celle de l'iPhone)

Chaque fichier est fermé proprement toutes les 10 minutes : si le PC s'éteint, on perd
au plus la tranche en cours.
"""
import os
import json
import time
import queue
import threading

import numpy as np

FREQ = 16000
MINUTES_PAR_FICHIER = 10
DUREE_MAX_S = 14 * 3600          # arrêt automatique de sécurité
NOM_MICRO = "yeti"


def ajouter_ligne(chemin, donnees):
    with open(chemin, "a", encoding="utf-8") as f:
        f.write(json.dumps(donnees, ensure_ascii=False) + "\n")


class SourceMicro:
    """Micro réel (sounddevice). Préfère le Blue Yeti ; sinon le micro par défaut."""

    def __init__(self, rappel):
        import sounddevice as sd
        self.sd = sd
        self.rappel = rappel
        self.flux = None
        self.nom = None
        self.freq = None
        self.yeti = False

    def candidats(self):
        sd = self.sd
        apis = sd.query_hostapis()
        preference = {"MME": 0, "Windows DirectSound": 1, "Windows WASAPI": 2}
        yeti, autres = [], []
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] < 1:
                continue
            api = apis[d["hostapi"]]["name"]
            if "WDM-KS" in api:
                continue
            entree = (preference.get(api, 5), i, d["name"])
            (yeti if NOM_MICRO in d["name"].lower() else autres).append(entree)
        yeti.sort()
        autres.sort()
        return [(i, n, True) for _, i, n in yeti] + [(i, n, False) for _, i, n in autres]

    def demarrer(self):
        sd = self.sd
        for index, nom, est_yeti in self.candidats():
            defaut = int(sd.query_devices(index)["default_samplerate"])
            for freq in (FREQ, 48000, 44100, defaut):
                for canaux in (1, 2):
                    try:
                        flux = sd.InputStream(device=index, samplerate=freq, channels=canaux, dtype="float32",
                                              blocksize=int(freq * 0.1),
                                              callback=lambda data, n, t, statut, f=freq:
                                              self.rappel(time.time(), data.copy(), f))
                        flux.start()
                    except Exception:
                        continue
                    self.flux, self.nom, self.freq, self.yeti = flux, nom, freq, est_yeti
                    return
        raise RuntimeError("aucun micro utilisable (le Blue Yeti est-il branché ? une autre app l'utilise-t-elle ?)")

    def arreter(self):
        if self.flux is not None:
            try:
                self.flux.stop()
                self.flux.close()
            except Exception:
                pass
            self.flux = None


class EcrivainFlac:
    """Convertit en mono 16 kHz et écrit des FLAC de 10 minutes, avec un index."""

    def __init__(self, dossier, freq_entree):
        import soundfile
        self.sf = soundfile
        self.dossier = dossier
        os.makedirs(dossier, exist_ok=True)
        self.index = os.path.join(dossier, "index.jsonl")
        self.resampler = None
        if freq_entree != FREQ:
            import soxr
            self.resampler = soxr.ResampleStream(freq_entree, FREQ, 1, dtype="float32")
        self.freq_entree = freq_entree
        self.taille = int(MINUTES_PAR_FICHIER * 60 * FREQ)
        existants = [n for n in os.listdir(dossier) if n.startswith("y_") and n.endswith(".flac")]
        self.numero = len(existants)
        self.fichier = None
        self.nom = None
        self.debut = None
        self.ecrits = 0
        self.total = 0
        self.niveau_db = -120.0

    def _ouvrir(self, heure):
        self._fermer()
        self.nom = "y_%05d.flac" % self.numero
        self.numero += 1
        self.fichier = self.sf.SoundFile(os.path.join(self.dossier, self.nom), "w", samplerate=FREQ, channels=1,
                                         format="FLAC", subtype="PCM_16")
        self.debut = heure
        self.ecrits = 0
        ajouter_ligne(self.index, {"file": "yeti/" + self.nom, "startUnix": heure, "frames": 0,
                                   "sampleRate": FREQ, "complete": False})

    def _fermer(self):
        if self.fichier is None:
            return
        self.fichier.close()
        ajouter_ligne(self.index, {"file": "yeti/" + self.nom, "startUnix": self.debut, "frames": self.ecrits,
                                   "sampleRate": FREQ, "complete": True})
        self.fichier = None

    def ecrire(self, heure_arrivee, bloc):
        x = bloc.mean(axis=1) if bloc.ndim == 2 else bloc
        x = np.ascontiguousarray(x, dtype=np.float32)
        rms = float(np.sqrt(np.mean(x * x) + 1e-20))
        self.niveau_db = 0.8 * self.niveau_db + 0.2 * (20 * np.log10(rms))
        heure_bloc = heure_arrivee - len(x) / self.freq_entree      # heure du premier échantillon
        if self.resampler is not None:
            x = self.resampler.resample_chunk(x)
        pos = 0
        while pos < len(x):
            if self.fichier is None or self.ecrits >= self.taille:
                self._ouvrir(heure_bloc + pos / FREQ)
            n = min(self.taille - self.ecrits, len(x) - pos)
            self.fichier.write(np.clip(x[pos:pos + n], -1, 1))
            self.ecrits += n
            self.total += n
            pos += n

    def fermer(self):
        self._fermer()
        self.resampler = None


class EnregistreurYeti:
    """Démarre et arrête l'enregistrement à la demande de l'app. Utilisable depuis plusieurs fils."""

    def __init__(self, fabrique_source=SourceMicro, journal=print, duree_max=DUREE_MAX_S):
        self.fabrique_source = fabrique_source
        self.journal = journal
        self.duree_max = duree_max
        self.verrou = threading.Lock()
        self.source = None
        self.ecrivain = None
        self.file = None
        self.fil = None
        self.seance = None
        self.dossier = None
        self.debut = None
        self.erreur = None
        self.minuterie = None

    # -------------------------------------------------------------- commandes
    def demarrer(self, dossier_seance, seance, heure_iphone=None):
        with self.verrou:
            if self.seance == seance and self.source is not None:
                self._noter_horloge(heure_iphone)
                return self._etat()
            if self.source is not None:
                self._arreter("nouvelle séance demandée")
            self.erreur = None
            self.dossier = os.path.join(dossier_seance, "yeti")
            os.makedirs(self.dossier, exist_ok=True)
            self.file = queue.Queue()
            try:
                source = self.fabrique_source(lambda heure, bloc, freq: self.file.put((heure, bloc, freq)))
                source.demarrer()
            except Exception as e:
                self.erreur = str(e)
                self.journal("  Yeti : impossible de démarrer (%s)" % e)
                ajouter_ligne(os.path.join(self.dossier, "evenements.jsonl"),
                              {"unix": time.time(), "type": "erreur", "message": str(e)})
                return self._etat()
            self.source = source
            self.seance = seance
            self.debut = time.time()
            self.ecrivain = EcrivainFlac(self.dossier, source.freq)
            self.fil = threading.Thread(target=self._ecrire, args=(self.file, self.ecrivain), daemon=True)
            self.fil.start()
            self._noter_horloge(heure_iphone)
            ajouter_ligne(os.path.join(self.dossier, "evenements.jsonl"),
                          {"unix": self.debut, "type": "debut", "message": "Enregistrement démarré",
                           "micro": source.nom, "yeti": bool(source.yeti), "frequence_micro": source.freq})
            self.minuterie = threading.Timer(self.duree_max, lambda: self.arreter(raison="durée maximale atteinte"))
            self.minuterie.daemon = True
            self.minuterie.start()
            self.journal("  Yeti : enregistrement démarré pour la séance %s (micro : %s%s)"
                         % (seance, source.nom, "" if source.yeti else " — Blue Yeti introuvable"))
            return self._etat()

    def arreter(self, seance=None, raison="demandé par l'app"):
        with self.verrou:
            if self.source is None or (seance is not None and seance != self.seance):
                return self._etat()
            self._arreter(raison)
            return self._etat()

    def etat(self, heure_iphone=None):
        with self.verrou:
            if self.source is not None:
                self._noter_horloge(heure_iphone)
            return self._etat()

    # -------------------------------------------------------------- interne
    def _arreter(self, raison):
        if self.minuterie is not None:
            self.minuterie.cancel()
            self.minuterie = None
        self.source.arreter()
        self.file.put(None)
        self.fil.join(timeout=30)
        duree = self.ecrivain.total / FREQ if self.ecrivain else 0
        ajouter_ligne(os.path.join(self.dossier, "evenements.jsonl"),
                      {"unix": time.time(), "type": "fin", "message": "Enregistrement arrêté (%s)" % raison,
                       "secondes": duree})
        self.journal("  Yeti : enregistrement arrêté (%s), %.0f min de son" % (raison, duree / 60))
        self.source = None
        self.derniere = {"seance": self.seance, "secondes": duree, "raison": raison}
        self.seance = None

    def _ecrire(self, file, ecrivain):
        while True:
            element = file.get()
            if element is None:
                break
            heure, bloc, _ = element
            try:
                ecrivain.ecrire(heure, bloc)
            except Exception as e:
                self.erreur = "écriture impossible : %s" % e
        ecrivain.fermer()

    def _noter_horloge(self, heure_iphone):
        if heure_iphone is None or self.dossier is None:
            return
        try:
            heure_iphone = float(heure_iphone)
        except (TypeError, ValueError):
            return
        maintenant = time.time()
        ajouter_ligne(os.path.join(self.dossier, "horloge.jsonl"),
                      {"unix_pc": maintenant, "unix_iphone": heure_iphone,
                       "pc_moins_iphone_s": maintenant - heure_iphone})

    def _etat(self):
        actif = self.source is not None
        etat = {"enregistre": actif, "seance": self.seance, "erreur": self.erreur}
        if actif:
            etat.update({"depuis_unix": self.debut,
                         "secondes": (self.ecrivain.total / FREQ) if self.ecrivain else 0,
                         "niveau_db": round(self.ecrivain.niveau_db, 1) if self.ecrivain else None,
                         "micro": self.source.nom, "yeti": bool(self.source.yeti)})
        elif getattr(self, "derniere", None):
            etat["derniere"] = self.derniere
        return etat
