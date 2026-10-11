# -*- coding: utf-8 -*-
"""
Lecture d'une séance enregistrée par l'app iPhone « Sommeil » (v2).
Le format est décrit dans FORMAT.md.

    from lecture_iphone import Seance
    s = Seance("iphone_v2/2026-10-10_23h14m05")
    t, v = s.flux("dm")          # t : horloge des capteurs (s), v : tableau (n, 13)
    unix = s.vers_unix(t)        # heure réelle
"""
import os
import re
import json
import struct

import numpy as np

ENTETE = struct.Struct("<8sHHHHdddI20s")      # 64 octets
MAGIQUE = b"SOMNBIN1"
FLUX = {
    1: ("dm", ["ux", "uy", "uz", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw"]),
    2: ("acc", ["x", "y", "z"]),
    3: ("gyr", ["x", "y", "z"]),
}
NOMS_FLUX = {v[0]: (k, v[1]) for k, v in FLUX.items()}


class ErreurFormat(Exception):
    pass


def lire_entete(octets):
    if len(octets) < ENTETE.size:
        raise ErreurFormat("fichier trop court")
    magique, version, flux, taille, _, freq, uptime, unix, morceau, prefixe = ENTETE.unpack(octets[:ENTETE.size])
    if magique != MAGIQUE:
        raise ErreurFormat("ce n'est pas un fichier de capteurs Sommeil")
    if flux not in FLUX:
        raise ErreurFormat("flux inconnu : %d" % flux)
    return {"version": version, "flux": FLUX[flux][0], "champs": FLUX[flux][1], "taille": taille,
            "frequence": freq, "uptime_creation": uptime, "unix_creation": unix, "morceau": morceau,
            "prefixe": prefixe.rstrip(b"\0").decode("ascii", "replace")}


def lire_fichier(chemin):
    """Lit un fichier .bin. Renvoie (entête, t, valeurs). Un dernier enregistrement coupé est ignoré."""
    with open(chemin, "rb") as f:
        octets = f.read()
    entete = lire_entete(octets)
    k = len(entete["champs"])
    taille = entete["taille"]
    if taille != 8 + 4 * k:
        raise ErreurFormat("taille d'enregistrement inattendue (%d)" % taille)
    corps = octets[ENTETE.size:]
    n = len(corps) // taille
    dtype = np.dtype([("t", "<f8"), ("v", "<f4", (k,))])
    tableau = np.frombuffer(corps[:n * taille], dtype=dtype, count=n)
    return entete, tableau["t"].astype(np.float64), tableau["v"].astype(np.float64)


def lire_jsonl(chemin):
    """Lit un fichier JSON Lines ; les lignes abîmées sont ignorées."""
    lignes = []
    if not os.path.exists(chemin):
        return lignes
    with open(chemin, "rb") as f:
        for ligne in f:
            ligne = ligne.strip()
            if not ligne:
                continue
            try:
                lignes.append(json.loads(ligne.decode("utf-8")))
            except (ValueError, UnicodeDecodeError):
                continue
    return lignes


class Seance:
    def __init__(self, dossier):
        self.dossier = os.path.abspath(dossier)
        chemin_info = os.path.join(self.dossier, "session.json")
        if not os.path.exists(chemin_info):
            raise ErreurFormat("session.json introuvable dans %s" % self.dossier)
        with open(chemin_info, encoding="utf-8") as f:
            self.info = json.load(f)
        self.journal = lire_jsonl(os.path.join(self.dossier, "journal.jsonl"))
        self.etat = lire_jsonl(os.path.join(self.dossier, "etat.jsonl"))
        self.horloge = lire_jsonl(os.path.join(self.dossier, "horloge.jsonl"))
        self.resume = None
        chemin_resume = os.path.join(self.dossier, "resume.json")
        if os.path.exists(chemin_resume):
            with open(chemin_resume, encoding="utf-8") as f:
                self.resume = json.load(f)
        self._flux = {}

    # ------------------------------------------------------------ capteurs
    def fichiers_flux(self, prefixe):
        dossier = os.path.join(self.dossier, "capteurs")
        if not os.path.isdir(dossier):
            return []
        motif = re.compile(r"^%s_(\d+)\.bin$" % re.escape(prefixe))
        trouves = []
        for nom in os.listdir(dossier):
            m = motif.match(nom)
            if m:
                trouves.append((int(m.group(1)), os.path.join(dossier, nom)))
        return [c for _, c in sorted(trouves)]

    def flux(self, prefixe):
        """(t, valeurs) de tout un flux, tous les morceaux bout à bout, triés par horodatage."""
        if prefixe not in self._flux:
            ts, vs = [], []
            for chemin in self.fichiers_flux(prefixe):
                try:
                    _, t, v = lire_fichier(chemin)
                except ErreurFormat:
                    continue
                ts.append(t)
                vs.append(v)
            k = len(NOMS_FLUX[prefixe][1])
            if ts:
                t = np.concatenate(ts)
                v = np.concatenate(vs)
                ordre = np.argsort(t, kind="stable")
                self._flux[prefixe] = (t[ordre], v[ordre])
            else:
                self._flux[prefixe] = (np.zeros(0), np.zeros((0, k)))
        return self._flux[prefixe]

    def colonne(self, prefixe, champ):
        t, v = self.flux(prefixe)
        return t, v[:, NOMS_FLUX[prefixe][1].index(champ)]

    # ------------------------------------------------------------ horloges
    def vers_unix(self, uptime):
        """Convertit l'horloge des capteurs en heure réelle (secondes depuis 1970)."""
        uptime = np.asarray(uptime, dtype=float)
        if self.horloge:
            u = np.array([p["uptime"] for p in self.horloge])
            x = np.array([p["unix"] for p in self.horloge])
            decalage = np.interp(uptime, u, x - u)
            return uptime + decalage
        return uptime + (self.info["startUnix"] - self.info["startUptime"])

    @property
    def debut_uptime(self):
        return self.info["startUptime"]

    def relatif(self, uptime):
        """Secondes depuis le début de la séance."""
        return np.asarray(uptime, dtype=float) - self.debut_uptime

    # ------------------------------------------------------------ journal
    def evenements(self, type_=None):
        return [e for e in self.journal if type_ is None or e.get("type") == type_]

    def marqueurs(self):
        """Marqueurs du test guidé : liste de (secondes depuis le début, nom, consigne)."""
        res = []
        for e in self.evenements("marqueur"):
            nom = (e.get("info") or {}).get("marqueur", "?")
            t = (e.get("values") or {}).get("t_test_s")
            if t is None:
                t = e["uptime"] - self.debut_uptime
            res.append((float(t), nom, e.get("message", "")))
        return sorted(res)

    # ------------------------------------------------------------ son
    def segments_audio(self):
        """Fichiers son connus (dernière ligne de l'index pour chaque fichier)."""
        derniers = {}
        for ligne in lire_jsonl(os.path.join(self.dossier, "audio", "index.jsonl")):
            derniers[ligne["file"]] = ligne
        return sorted(derniers.values(), key=lambda s: s["startUptime"])

    def lire_audio(self, segment):
        """Échantillons (float32, 16 kHz mono) d'un fichier son. Nécessite PyAV."""
        import av
        chemin = os.path.join(self.dossier, segment["file"])
        morceaux = []
        with av.open(chemin) as conteneur:
            for trame in conteneur.decode(audio=0):
                x = trame.to_ndarray()
                if x.dtype.kind in "iu":
                    x = x.astype(np.float32) / float(np.iinfo(x.dtype).max)
                morceaux.append(x.reshape(-1).astype(np.float32))
        return np.concatenate(morceaux) if morceaux else np.zeros(0, dtype=np.float32)

    # ------------------------------------------------------------ Blue Yeti (PC)
    def segments_yeti(self):
        """Fichiers du Blue Yeti enregistrés par le PC pendant la séance (dernière ligne par fichier)."""
        derniers = {}
        for ligne in lire_jsonl(os.path.join(self.dossier, "yeti", "index.jsonl")):
            derniers[ligne["file"]] = ligne
        return sorted(derniers.values(), key=lambda s: s["startUnix"])

    def decalage_pc(self):
        """Écart médian horloge du PC − horloge de l'iPhone (secondes), ou None.
        L'heure du Yeti (startUnix, horloge du PC) − ce décalage = heure de l'iPhone."""
        points = [l["pc_moins_iphone_s"] for l in lire_jsonl(os.path.join(self.dossier, "yeti", "horloge.jsonl"))
                  if "pc_moins_iphone_s" in l]
        return float(np.median(points)) if points else None

    def lire_yeti(self, segment):
        """Échantillons (16 kHz mono) d'un fichier du Yeti. Nécessite soundfile."""
        import soundfile
        x, _ = soundfile.read(os.path.join(self.dossier, segment["file"]), dtype="float32")
        return x

