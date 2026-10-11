# -*- coding: utf-8 -*-
"""
Vérification d'une séance de l'app Sommeil (phase 1).

Répond aux questions de la phase 1, à partir des données brutes :
  - quelle fréquence est réellement obtenue, avec quelle régularité, y a-t-il des trous ?
  - les battements du cœur sont-ils visibles, et sur quels axes ?
  - la respiration est-elle visible ? les arrêts de respiration du test guidé se voient-ils ?
  - le son est-il complet et lisible ? combien de batterie par heure ?

Usage : python verifier_seance.py <dossier de la séance>   (écrit aussi verification.txt)
"""
import os
import sys
import json
import datetime

import numpy as np
from scipy.signal import butter, sosfiltfilt

from lecture_iphone import Seance

FS = 100.0
SEUIL_TROU = 0.25

# Segments immobiles du test guidé (secondes depuis le début) et leur position attendue.
SEGMENTS_TEST = [
    ("sur le dos", 35, 150),
    ("sur le dos (après l'arrêt de respiration)", 180, 240),
    ("côté gauche", 315, 420),
    ("côté gauche (après l'arrêt de respiration)", 450, 505),
    ("côté droit", 525, 598),
]
APNEES = [("1er arrêt (sur le dos)", 155, 175), ("2e arrêt (côté gauche)", 425, 445)]
MOUVEMENTS = (240, 260)


# ------------------------------------------------------------------ signaux
def passe_bande(x, bas, haut, fs, ordre=4):
    sos = butter(ordre, [bas, min(haut, 0.45 * fs)], btype="band", fs=fs, output="sos")
    return sosfiltfilt(sos, x - np.mean(x))


def passe_bas(x, coupure, fs, ordre=4):
    sos = butter(ordre, coupure, btype="low", fs=fs, output="sos")
    return sosfiltfilt(sos, x)


def enveloppe_cardiaque(x, fs=FS):
    """Même méthode que l'app : bande 5-25 Hz, énergie lissée à 4 Hz, racine, écrêtage."""
    y = passe_bande(x, 5, 25, fs)
    env = np.sqrt(np.maximum(passe_bas(y * y, 4, fs), 0))
    plafond = np.percentile(env, 98) * 1.5
    if plafond > 0:
        env = np.minimum(env, plafond)
    return env - env.mean()


def autocorrelation(x, lags):
    energie = float(np.dot(x, x))
    if energie <= 0:
        return np.zeros(len(lags))
    n = len(x)
    return np.array([np.dot(x[:n - k], x[k:]) / energie if k < n else 0.0 for k in lags])


def pic_fondamental(ac, lag0, fraction=0.8):
    """Plus petit décalage dont le sommet atteint `fraction` du plus haut sommet (interpolé)."""
    sommets = []
    for i in range(1, len(ac) - 1):
        if ac[i] >= ac[i - 1] and ac[i] > ac[i + 1]:
            a, b, c = ac[i - 1], ac[i], ac[i + 1]
            den = a - 2 * b + c
            off = 0.0 if abs(den) < 1e-12 else max(-0.5, min(0.5, 0.5 * (a - c) / den))
            sommets.append((lag0 + i + off, b - 0.25 * (a - c) * off))
    if not sommets:
        return None
    haut = max(v for _, v in sommets)
    if haut <= 0:
        return None
    return next((l, v) for l, v in sommets if v >= fraction * haut)


def pouls(x, fs=FS, bpm_min=40, bpm_max=150):
    """(bpm ou None, qualité 0-1) sur une fenêtre."""
    env = enveloppe_cardiaque(x, fs)
    lag_min, lag_max = int(fs * 60 / bpm_max), int(np.ceil(fs * 60 / bpm_min))
    if len(env) <= 2 * lag_max:
        return None, 0.0
    lags = np.arange(lag_min - 1, lag_max + 2)
    pic = pic_fondamental(autocorrelation(env, lags), lag_min - 1)
    if pic is None:
        return None, 0.0
    lag, valeur = pic
    qualite = float(np.clip(valeur * len(env) / (len(env) - lag), 0, 1))
    bpm = 60 * fs / lag
    return (bpm if qualite > 0.05 else None), qualite


def respiration(gx, gy, gz, fs=FS):
    """(par minute ou None, qualité, amplitude en degrés, signal filtré à 10 Hz)."""
    f = max(1, int(round(fs / 10)))
    n = len(gx) // f * f
    g = np.stack([a[:n].reshape(-1, f).mean(axis=1) for a in (gx, gy, gz)], axis=1)
    rate = fs / f
    if len(g) < rate * 20:
        return None, 0.0, 0.0, np.zeros(0)
    g = g - g.mean(axis=0)
    _, vecteurs = np.linalg.eigh(np.cov(g.T))
    p = g @ vecteurs[:, -1]
    sos = butter(2, [0.1, 0.7], btype="band", fs=rate, output="sos")
    s = sosfiltfilt(sos, p)
    amplitude = float(np.degrees(np.arcsin(min(1.0, np.percentile(s, 95) - np.percentile(s, 5)))))
    lag_min, lag_max = int(rate * 60 / 40), int(np.ceil(rate * 60 / 6))
    lags = np.arange(lag_min - 1, lag_max + 2)
    pic = pic_fondamental(autocorrelation(s, lags), lag_min - 1)
    if pic is None:
        return None, 0.0, amplitude, s
    lag, valeur = pic
    qualite = float(np.clip(valeur * len(s) / (len(s) - lag), 0, 1))
    return (60 * rate / lag if qualite > 0.1 else None), qualite, amplitude, s


def respiration_gyro(rx, ry, rz, fs=FS):
    """Respiration à partir du gyroscope : on intègre la rotation pour retrouver l'inclinaison
    du thorax. Marche dans toutes les positions (la gravité, elle, voit mal la respiration sur le côté)."""
    f = max(1, int(round(fs / 10)))
    n = len(rx) // f * f
    w = np.stack([a[:n].reshape(-1, f).mean(axis=1) for a in (rx, ry, rz)], axis=1)
    rate = fs / f
    if len(w) < rate * 20:
        return None, 0.0, 0.0
    angle = np.cumsum(w - w.mean(axis=0), axis=0) / rate
    sos = butter(2, [0.1, 0.7], btype="band", fs=rate, output="sos")
    angle = sosfiltfilt(sos, angle, axis=0)
    _, vecteurs = np.linalg.eigh(np.cov(angle.T))
    s = angle @ vecteurs[:, -1]
    amplitude = float(np.degrees(np.percentile(s, 95) - np.percentile(s, 5)))
    lag_min, lag_max = int(rate * 60 / 40), int(np.ceil(rate * 60 / 6))
    pic = pic_fondamental(autocorrelation(s, np.arange(lag_min - 1, lag_max + 2)), lag_min - 1)
    if pic is None:
        return None, 0.0, amplitude
    lag, valeur = pic
    qualite = float(np.clip(valeur * len(s) / (len(s) - lag), 0, 1))
    return (60 * rate / lag if qualite > 0.1 else None), qualite, amplitude


def agitation(ux, uy, uz):
    return float(np.std(np.sqrt(ux ** 2 + uy ** 2 + uz ** 2)))


# ------------------------------------------------------------------ rapport
class Rapport:
    def __init__(self):
        self.lignes = []
        self.resultats = {}

    def titre(self, texte):
        self.lignes += ["", texte, "-" * len(texte)]

    def __call__(self, texte=""):
        self.lignes.append(texte)

    def texte(self):
        return "\n".join(self.lignes).strip() + "\n"


def fenetres(debut, fin, duree, pas):
    t = debut
    while t + duree <= fin:
        yield t, t + duree
        t += pas


def selection(t_rel, a, b):
    return (t_rel >= a) & (t_rel < b)


def segments_immobiles(seance, t_rel, ux, uy, uz, est_test):
    """Segments où l'on peut regarder le pouls : ceux du test guidé, ou les passages calmes d'une nuit."""
    if est_test:
        return [(nom, a, b) for nom, a, b in SEGMENTS_TEST if b <= t_rel[-1] + 1]
    segments = []
    fin = t_rel[-1] if len(t_rel) else 0
    # Tranches de 30 s dès le début (une séance courte en a donc au moins une).
    duree = 30 if fin >= 30 else max(10, fin)
    for a, b in fenetres(0, fin, duree, duree):
        m = selection(t_rel, a, b)
        if m.sum() > 50 and agitation(ux[m], uy[m], uz[m]) < 0.008:
            segments.append(("calme à %s" % temps_txt(a), a, b))
    if len(segments) > 40:          # on en garde 40, répartis sur la nuit
        idx = np.linspace(0, len(segments) - 1, 40).astype(int)
        segments = [segments[i] for i in idx]
    return segments


def qualite_cardiaque(signaux, fs=FS):
    """Qualité combinée des battements sur une fenêtre (gyro X, gyro Y, accél Z…), et pouls."""
    envs, poids, meilleure = [], [], 0.0
    for x in signaux:
        _, q = pouls(x, fs)
        meilleure = max(meilleure, q)
        e = enveloppe_cardiaque(x, fs)
        if e.std() > 0:
            envs.append(e / e.std())
            poids.append(q * q)
    if not envs or sum(poids) <= 0:
        return meilleure, None
    mix = np.sum([p * e for p, e in zip(poids, envs)], axis=0)
    mix -= mix.mean()
    lag_min, lag_max = int(fs * 60 / 150), int(np.ceil(fs * 60 / 40))
    pic = pic_fondamental(autocorrelation(mix, np.arange(lag_min - 1, lag_max + 2)), lag_min - 1)
    if not pic:
        return meilleure, None
    q = float(np.clip(pic[1] * len(mix) / (len(mix) - pic[0]), 0, 1))
    return max(q, meilleure), 60 * fs / pic[0]


def position(g, calib):
    """Position du corps d'après la gravité, comparée à la calibration (sur le dos).
    Gauche/droite suppose le téléphone en hauteur, haut vers la tête."""
    if calib is None:
        return "?", float("nan")
    g = np.asarray(g, dtype=float)
    g = g / max(np.linalg.norm(g), 1e-9)
    g0 = np.asarray(calib, dtype=float)
    angle = float(np.degrees(np.arccos(np.clip(np.dot(g, g0), -1, 1))))
    if angle < 40:
        return "dos", angle
    if angle > 140:
        return "ventre", angle
    return ("côté G" if np.cross(g0, g)[1] < 0 else "côté D"), angle


def tenue_telephone(t_rel, col, calib, duree_bloc):
    """Qualité des battements au fil de la séance, par blocs, pour voir si le téléphone a tenu."""
    blocs = []
    fin = t_rel[-1]
    debuts = list(np.arange(0, fin - duree_bloc / 2, duree_bloc))      # dernier bloc gardé s'il fait au moins la moitié
    for a in debuts:
        a, b = float(a), float(min(a + duree_bloc, fin))
        qs, calme, total, poss = [], 0, 0, []
        for fa, fb in fenetres(a, b, 10, 10):
            m = selection(t_rel, fa, fb)
            if m.sum() < FS * 9:
                continue
            total += 1
            if agitation(col["ux"][m], col["uy"][m], col["uz"][m]) > 0.02:
                continue
            calme += 1
            q, _ = qualite_cardiaque([col["rx"][m], col["ry"][m], col["uz"][m]])
            qs.append(q)
            poss.append(position([col["gx"][m].mean(), col["gy"][m].mean(), col["gz"][m].mean()], calib)[0])
        if total == 0:
            continue
        # Position la plus fréquente du bloc (une moyenne mélangerait deux côtés).
        pos = max(set(poss), key=poss.count) if poss else "bouge"
        blocs.append({"debut_s": float(a), "position": pos,
                      "calme": calme / total, "qualite": float(np.median(qs)) if qs else None,
                      "nets": float(np.mean(np.array(qs) >= 0.5)) if qs else None})
    # Glissement possible : la qualité s'effondre et ne revient pas, sans changement de position.
    for i in range(1, len(blocs) - 1):
        avant, ici, apres = blocs[i - 1], blocs[i], blocs[i + 1]
        if (avant["qualite"] or 0) >= 0.45 and ici["qualite"] is not None and apres["qualite"] is not None \
                and ici["qualite"] < 0.6 * avant["qualite"] and apres["qualite"] < 0.6 * avant["qualite"] \
                and ici["position"] == avant["position"]:
            ici["alerte"] = "signal effondré sans changement de position : le téléphone a peut-être glissé"
    return blocs


def temps_txt(s):
    s = int(round(s))
    return "%d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60) if s >= 3600 else "%d:%02d" % (s // 60, s % 60)


def inclinaison_deg(g):
    """Inclinaison du téléphone par rapport à « à plat » (comme Calibration.tiltDegrees dans l'app)."""
    return float(np.degrees(np.arccos(min(1.0, abs(g[2]) / max(np.linalg.norm(g), 1e-9)))))


def calibration_sur_le_dos(info):
    """La calibration correspond-elle bien à « sur le dos » ? (sinon on se repère à l'orientation du téléphone)"""
    calib = info.get("calibration") or {}
    g = calib.get("gravity")
    if not g:
        return False
    if inclinaison_deg(g) > 35:
        return False
    # Calibration automatique : écran vers le haut exigé (téléphone posé dos contre la peau).
    if info.get("calibrationMode") == "automatique" and g[2] >= 0:
        return False
    return True


def ligne_calibration(r, info, est_test):
    calib = info.get("calibration")
    auto = info.get("calibrationMode") == "automatique"
    if not calib or not calib.get("gravity"):
        if not est_test:
            r("Calibration : aucune%s" % (" (automatique : pas assez de mesures)" if auto else ""))
        return
    heure = datetime.datetime.fromtimestamp(float(calib.get("startUnix", 0))).strftime("%H:%M")
    calme = calib.get("movement", 1) < 0.02
    if auto and not calibration_sur_le_dos(info):
        etat = "aucun moment calme sur le dos trouvé, meilleure tranche gardée"
    else:
        etat = ("calme" if calme else "tu bougeais") + (", sur le dos" if calibration_sur_le_dos(info) else "")
    r("Calibration %s : %s, inclinaison %.0f°, %s" % ("automatique" if auto else "guidée", heure,
                                                     inclinaison_deg(calib["gravity"]), etat))
    r.resultats["calibration"] = {"mode": "automatique" if auto else "guidee", "sur_le_dos": calibration_sur_le_dos(info),
                                  "calme": calme, "inclinaison_deg": inclinaison_deg(calib["gravity"])}


def verifier(dossier):
    r = Rapport()
    s = Seance(dossier)
    info = s.info
    est_test = info.get("kind") == "test_guide"
    r("Vérification de la séance %s" % info.get("id"))
    r("Type : %s · appareil %s · iOS %s · app %s" % (info.get("kind"), info.get("device"),
                                                    info.get("systemVersion"), info.get("appVersion")))
    if s.resume:
        r("Durée : %s · fin %s" % (temps_txt(s.resume["duration"]),
                                  "normale" if s.resume["endedNormally"] else "NON PRÉVUE (app arrêtée par iOS ?)"))
    differe = info.get("delayedStart")
    if differe:
        demande = datetime.datetime.fromtimestamp(float(differe.get("requestedUnix", 0))).strftime("%H:%M")
        r("Début différé : « Oui » touché à %s (%s), enregistrement commencé %d min plus tard"
          % (demande, "depuis la notification" if differe.get("source") == "notification" else "dans l'app",
             int(differe.get("delayMinutes", 0))))
        r.resultats["debut_differe"] = differe
    ligne_calibration(r, info, est_test)
    if "verite_simulation.json" in os.listdir(s.dossier):
        r("(séance SIMULÉE : les valeurs vraies sont connues)")

    # ---------------------------------------------------------------- capteurs
    r.titre("1. Fréquence réelle des capteurs")
    r.resultats["flux"] = {}
    for prefixe, nom in (("dm", "mouvement fusionné"), ("acc", "accéléromètre brut"), ("gyr", "gyroscope brut")):
        t, _ = s.flux(prefixe)
        if len(t) < 2:
            r("%-20s absent" % nom)
            continue
        dt = np.diff(t)
        reguliers = dt[(dt > 0) & (dt <= SEUIL_TROU)]
        trous = dt[dt > SEUIL_TROU]
        freq = 1 / np.median(reguliers) if len(reguliers) else 0
        res = {"mesures": int(len(t)), "frequence_hz": float(freq),
               "frequence_moyenne_hz": float(len(reguliers) / reguliers.sum()) if len(reguliers) else 0,
               "irregularite_ms": float(np.std(reguliers) * 1000) if len(reguliers) else 0,
               "p99_ms": float(np.percentile(reguliers, 99) * 1000) if len(reguliers) else 0,
               "trous": int(len(trous)), "duree_trous_s": float(trous.sum()),
               "intervalle_max_s": float(dt.max()), "retours_arriere": int((dt <= 0).sum())}
        r.resultats["flux"][prefixe] = res
        r("%-20s %8d mesures · %.2f Hz · irrégularité ±%.2f ms (99 %% < %.1f ms) · %d trou(s) (%.1f s) · plus grand écart %.2f s"
          % (nom, res["mesures"], res["frequence_hz"], res["irregularite_ms"], res["p99_ms"], res["trous"],
             res["duree_trous_s"], res["intervalle_max_s"]))
    dm = r.resultats["flux"].get("dm")
    if dm:
        ok = dm["frequence_hz"] > 95 and dm["irregularite_ms"] < 3
        r("→ %s" % ("Fréquence et régularité correctes pour le pouls." if ok else
                    "ATTENTION : fréquence ou régularité insuffisante pour le pouls."))
    decalages = [e["values"]["decalage_horloge_s"] for e in s.journal
                 if (e.get("values") or {}).get("decalage_horloge_s") is not None]
    if decalages:
        r("Décalage entre horloge des capteurs/du son et horloge du système : %s ms"
          % ", ".join("%.1f" % (1000 * d) for d in decalages))
    if len(s.horloge) > 2:
        d = np.array([p["unix"] - p["uptime"] for p in s.horloge])
        r("Dérive horloge réelle / horloge des capteurs sur la séance : %.1f ms" % (1000 * (d.max() - d.min())))

    t_dm, v_dm = s.flux("dm")
    if len(t_dm) < FS * 30:
        r("\nPas assez de données de mouvement pour aller plus loin.")
        return r
    t_rel = s.relatif(t_dm)
    col = {c: v_dm[:, i] for i, c in enumerate(["ux", "uy", "uz", "gx", "gy", "gz", "rx", "ry", "rz"])}
    voies = [("accél X", col["ux"]), ("accél Y", col["uy"]), ("accél Z", col["uz"]),
             ("gyro X", col["rx"]), ("gyro Y", col["ry"]), ("gyro Z", col["rz"])]
    for prefixe, libelle in (("acc", "accél brut"), ("gyr", "gyro brut")):
        t_b, v_b = s.flux(prefixe)
        if len(t_b) > FS * 30:
            for i, axe in enumerate("XYZ"):
                voies.append(("%s %s" % (libelle, axe), np.interp(t_dm, t_b, v_b[:, i])))

    # ---------------------------------------------------------------- pouls
    r.titre("2. Battements du cœur (fenêtres de 10 s dans les passages immobiles)")
    segments = segments_immobiles(s, t_rel, col["ux"], col["uy"], col["uz"], est_test)
    if not segments:
        r("Aucun passage assez calme trouvé.")
    stats_voies = {nom: {"q": [], "bpm": []} for nom, _ in voies}
    combine = {"q": [], "bpm": []}
    par_segment = []
    for nom_seg, a, b in segments:
        q_seg = []
        for fa, fb in fenetres(a, b, 10, 5):
            m = selection(t_rel, fa, fb)
            if m.sum() < FS * 9:
                continue
            envs, poids = [], []
            for nom, x in voies:
                bpm, q = pouls(x[m])
                stats_voies[nom]["q"].append(q)
                if bpm:
                    stats_voies[nom]["bpm"].append(bpm)
                if not nom.startswith(("accél brut", "gyro brut")):
                    e = enveloppe_cardiaque(x[m])
                    if e.std() > 0:
                        envs.append(e / e.std())
                        poids.append(q * q)
            if envs and sum(poids) > 0:
                mix = np.sum([p * e for p, e in zip(poids, envs)], axis=0)
                mix -= mix.mean()
                lag_min, lag_max = int(FS * 60 / 150), int(np.ceil(FS * 60 / 40))
                pic = pic_fondamental(autocorrelation(mix, np.arange(lag_min - 1, lag_max + 2)), lag_min - 1)
                if pic:
                    q = float(np.clip(pic[1] * len(mix) / (len(mix) - pic[0]), 0, 1))
                    combine["q"].append(q)
                    q_seg.append(q)
                    if q > 0.05:
                        combine["bpm"].append(60 * FS / pic[0])
        if q_seg:
            par_segment.append((nom_seg, float(np.median(q_seg))))
    classement = sorted(((np.median(v["q"]) if v["q"] else 0, nom, v) for nom, v in stats_voies.items()), reverse=True)
    r("%-16s %8s %10s %14s" % ("voie", "qualité", "≥ 0,5", "pouls médian"))
    for q, nom, v in classement:
        bon = 100 * np.mean(np.array(v["q"]) >= 0.5) if v["q"] else 0
        bpm = "%.0f bpm" % np.median(v["bpm"]) if v["bpm"] else "—"
        r("%-16s %8.2f %9.0f %% %14s" % (nom, q, bon, bpm))
    if combine["q"]:
        q = float(np.median(combine["q"]))
        bon = 100 * np.mean(np.array(combine["q"]) >= 0.5)
        bpm = float(np.median(combine["bpm"])) if combine["bpm"] else None
        r("%-16s %8.2f %9.0f %% %14s" % ("combiné", q, bon, "%.0f bpm" % bpm if bpm else "—"))
        meilleure = max(q, classement[0][0] if classement else 0)
        r.resultats["pouls"] = {"qualite_combinee": q, "meilleure_voie": classement[0][1] if classement else None,
                                "qualite_meilleure_voie": float(classement[0][0]) if classement else 0,
                                "bpm_median": bpm, "par_segment": par_segment}
        if meilleure >= 0.5:
            r("→ Battements NETTEMENT visibles : le signal est exploitable pour le pouls.")
        elif meilleure >= 0.3:
            r("→ Battements visibles mais faibles : essayer un autre emplacement ou serrer davantage.")
        else:
            r("→ Battements PEU visibles : le pouls ne sera pas mesurable dans ces conditions.")
        for nom_seg, qs in par_segment[:12]:
            r("   %-45s qualité médiane %.2f" % (nom_seg, qs))
    verite = os.path.join(s.dossier, "verite_simulation.json")
    if os.path.exists(verite) and combine["bpm"]:
        with open(verite, encoding="utf-8") as f:
            vrai = json.load(f)
        battements = np.array(vrai["battements_s"])
        vrai_bpm = 60 / np.median(np.diff(battements))
        r("   (simulation : pouls vrai %.1f bpm, trouvé %.1f bpm)" % (vrai_bpm, np.median(combine["bpm"])))
        r.resultats["pouls"]["bpm_vrai"] = float(vrai_bpm)

    # ---------------------------------------------------------------- respiration
    r.titre("3. Respiration (mouvement du thorax, fenêtres de 30 s)")
    r("Deux méthodes : l'inclinaison vue par la gravité, et la rotation vue par le gyroscope.")
    zones = [(nom, a, b) for nom, a, b in segments] if est_test else [("nuit", 0, t_rel[-1])]
    r.resultats["respiration"] = []
    r("%-44s %24s %24s" % ("passage", "gravité", "gyroscope"))
    for nom_seg, a, b in zones:
        grav, gyro = [], []
        for fa, fb in fenetres(a, b, 30, 10 if est_test else 120):
            m = selection(t_rel, fa, fb)
            if m.sum() < FS * 25:
                continue
            if not est_test and agitation(col["ux"][m], col["uy"][m], col["uz"][m]) > 0.02:
                continue
            par_min, q, ampl, _ = respiration(col["gx"][m], col["gy"][m], col["gz"][m])
            grav.append((par_min, q, ampl))
            gyro.append(respiration_gyro(col["rx"][m], col["ry"][m], col["rz"][m]))
        if not grav:
            continue

        def resume(liste):
            q = float(np.median([x[1] for x in liste]))
            rates = [x[0] for x in liste if x[0]]
            ampl = float(np.median([x[2] for x in liste]))
            return q, (float(np.median(rates)) if rates else None), ampl

        qg, rg, ag = resume(grav)
        qy, ry, ay = resume(gyro)
        txt = lambda q, rt, am: "q %.2f · %s · %.2f°" % (q, "%4.1f/min" % rt if rt else "  —   ", am)
        r("%-44s %24s %24s" % (nom_seg, txt(qg, rg, ag), txt(qy, ry, ay)))
        r.resultats["respiration"].append({"passage": nom_seg, "gravite": {"qualite": qg, "par_minute": rg, "amplitude_deg": ag},
                                           "gyroscope": {"qualite": qy, "par_minute": ry, "amplitude_deg": ay}})
    if r.resultats["respiration"]:
        meilleures = [max(x["gravite"]["qualite"], x["gyroscope"]["qualite"]) for x in r.resultats["respiration"]]
        r("→ %s" % ("Respiration bien visible." if np.median(meilleures) >= 0.5 else
                    "Respiration peu nette dans ces conditions."))

    # ---------------------------------------------------------------- arrêts de respiration
    if est_test:
        r.titre("4. Arrêts de respiration du test guidé")
        sos = butter(2, [0.1, 0.7], btype="band", fs=FS, output="sos")
        r.resultats["apnees"] = []
        for nom, a, b in APNEES:
            if b + 5 > t_rel[-1]:
                continue
            m_large = selection(t_rel, a - 40, b + 20)
            gx, gy, gz = col["gx"][m_large], col["gy"][m_large], col["gz"][m_large]
            g = np.stack([gx, gy, gz], axis=1)
            g = g - g.mean(axis=0)
            _, vect = np.linalg.eigh(np.cov(g.T))
            p = sosfiltfilt(sos, g @ vect[:, -1])
            tl = t_rel[m_large]
            avant = p[(tl >= a - 25) & (tl < a - 3)]
            pendant = p[(tl >= a + 3) & (tl < b - 2)]
            if len(avant) < 100 or len(pendant) < 100:
                continue
            rapport = float(np.std(pendant) / max(np.std(avant), 1e-12))
            # Effort : le gyroscope bouge-t-il encore dans la bande de la respiration ?
            rot = np.sqrt(sosfiltfilt(sos, col["rx"][m_large]) ** 2 + sosfiltfilt(sos, col["ry"][m_large]) ** 2)
            effort = float(np.std(rot[(tl >= a + 3) & (tl < b - 2)]) / max(np.std(rot[(tl >= a - 25) & (tl < a - 3)]), 1e-12))
            vu = rapport < 0.4
            r.resultats["apnees"].append({"nom": nom, "rapport_amplitude": rapport, "rapport_rotation": effort, "visible": vu})
            r("%-24s amplitude pendant / avant = %.2f · rotation pendant / avant = %.2f → %s"
              % (nom, rapport, effort, "arrêt bien visible" if vu else "arrêt PAS net"))

        r.titre("5. Mouvements et positions")
        a, b = MOUVEMENTS
        if b < t_rel[-1]:
            m = selection(t_rel, a, b)
            calme = selection(t_rel, 60, 140)
            r("Agitation pendant les mouvements : %.3f g (au calme : %.4f g)"
              % (agitation(col["ux"][m], col["uy"][m], col["uz"][m]),
                 agitation(col["ux"][calme], col["uy"][calme], col["uz"][calme])))
        calib = (info.get("calibration") or {}).get("gravity")
        for nom, a, b in SEGMENTS_TEST:
            m = selection(t_rel, a, b)
            if m.sum() < 100:
                continue
            g = np.array([col["gx"][m].mean(), col["gy"][m].mean(), col["gz"][m].mean()])
            g = g / np.linalg.norm(g)
            angle = float(np.degrees(np.arccos(np.clip(np.dot(g, calib), -1, 1)))) if calib else float("nan")
            r("%-44s gravité (%.2f, %.2f, %.2f) · %.0f° par rapport à la calibration" % (nom, g[0], g[1], g[2], angle))

    # ---------------------------------------------------------------- tenue du téléphone
    if t_rel[-1] >= 240:
        duree_bloc = 600 if t_rel[-1] > 3600 else 60
        r.titre("Tenue du téléphone (battements nets au fil de la séance, blocs de %d min)" % (duree_bloc // 60))
        calib = (info.get("calibration") or {}).get("gravity")
        if calib and not calibration_sur_le_dos(info):
            if info.get("calibrationMode") == "automatique":
                r("Calibration automatique : aucun moment calme sur le dos trouvé pendant la nuit.")
                r("Les positions ci-dessous sont déduites de l'orientation du téléphone (à plat, écran vers le haut "
                  "= sur le dos).")
                calib = [0.0, 0.0, -1.0]
            else:
                r("Calibration faite avec le téléphone incliné de %.0f° : tu n'étais sans doute pas sur le dos."
                  % inclinaison_deg(calib))
                r("Les positions ci-dessous sont déduites de l'orientation du téléphone (à plat = sur le dos).")
                calib = [0.0, 0.0, float(np.sign(calib[2]) or -1.0)]
        blocs = tenue_telephone(t_rel, col, calib, duree_bloc)
        r.resultats["tenue"] = blocs
        r("%-9s %-8s %7s %9s %12s" % ("heure", "position", "calme", "qualité", "battements nets"))
        for bloc in blocs:
            heure = datetime.datetime.fromtimestamp(float(s.vers_unix(s.debut_uptime + bloc["debut_s"]))).strftime("%H:%M")
            q = "%.2f" % bloc["qualite"] if bloc["qualite"] is not None else "—"
            nets = "%.0f %%" % (100 * bloc["nets"]) if bloc["nets"] is not None else "—"
            r("%-9s %-8s %6.0f %% %9s %12s%s" % (heure, bloc["position"], 100 * bloc["calme"], q, nets,
                                                 "   ← " + bloc["alerte"] if bloc.get("alerte") else ""))
        qualites = [b["qualite"] for b in blocs if b["qualite"] is not None]
        if qualites:
            bons = np.mean(np.array(qualites) >= 0.5)
            r("→ Battements nets dans %.0f %% des blocs calmes. %s" % (
                100 * bons, "Le téléphone a bien tenu." if bons >= 0.8 else
                "Le signal faiblit par moments : vérifie le serrage et l'emplacement."))
        r("(gauche/droite : en supposant le téléphone en hauteur, le haut vers la tête)")

    # ---------------------------------------------------------------- son
    r.titre("6. Son")
    segs = s.segments_audio()
    if not segs:
        r("Aucun fichier son.")
    else:
        complets = [x for x in segs if x.get("complete")]
        duree = sum(x["frames"] / x["sampleRate"] for x in complets)
        r("%d fichier(s), %d complet(s), %s de son" % (len(segs), len(complets), temps_txt(duree)))
        try:
            import av  # noqa: F401
            niveaux = []
            illisibles = 0
            ecarts = []
            for seg in [segs[0], segs[len(segs) // 2], segs[-1]]:
                try:
                    x = s.lire_audio(seg)
                    if len(x):
                        niveaux.append(20 * np.log10(max(np.sqrt(np.mean(x.astype(np.float64) ** 2)), 1e-7)))
                    if seg.get("complete") and seg.get("frames"):
                        ecarts.append(len(x) - seg["frames"])
                except Exception:
                    illisibles += 1
            if ecarts and any(abs(e) > 0 for e in ecarts):
                r("Écart entre échantillons lus et annoncés : %s" % ", ".join(str(e) for e in ecarts))
            if niveaux:
                r("Lecture vérifiée sur 3 fichiers : niveau moyen %s dBFS%s"
                  % (", ".join("%.0f" % n for n in niveaux),
                     " · %d illisible(s)" % illisibles if illisibles else ""))
        except ImportError:
            r("(PyAV absent : lecture du son non vérifiée)")

    # ---------------------------------------------------------------- Blue Yeti
    yeti = s.segments_yeti()
    if yeti:
        r.titre("6 bis. Blue Yeti (PC)")
        complets = [x for x in yeti if x.get("complete")]
        duree = sum(x["frames"] / x["sampleRate"] for x in complets)
        decalage = s.decalage_pc()
        r("%d fichier(s), %d complet(s), %s de son" % (len(yeti), len(complets), temps_txt(duree)))
        if decalage is not None:
            r("Écart d'horloge PC − iPhone : %+.2f s (corrigé pour caler les deux enregistrements)" % decalage)
            debut = yeti[0]["startUnix"] - decalage - s.info["startUnix"]
            r("Le Yeti a commencé %s après le début de la séance iPhone" % temps_txt(max(0, debut)))
        if complets and len(complets) < len(yeti):
            r("Dernier fichier non terminé (PC éteint ou fenêtre fermée brutalement ?)")
        r.resultats["yeti"] = {"fichiers": len(yeti), "secondes": duree, "decalage_pc_s": decalage}
        try:
            x = s.lire_yeti(complets[len(complets) // 2]) if complets else []
            if len(x):
                r("Niveau moyen (fichier du milieu) : %.0f dBFS" % (20 * np.log10(np.sqrt(np.mean(np.square(x, dtype=np.float64))) + 1e-9)))
        except ImportError:
            r("(soundfile absent : lecture du Yeti non vérifiée)")

    # ---------------------------------------------------------------- batterie et journal
    r.titre("7. Batterie, interruptions, erreurs")
    if s.resume and s.resume.get("batteryDrainPerHour") is not None:
        conso = 100 * s.resume["batteryDrainPerHour"]
        r("Consommation : %.1f %% par heure → environ %.0f %% pour 8 heures" % (conso, conso * 8))
    niveaux = [e["battery"] for e in s.etat if e.get("battery") is not None]
    if niveaux:
        r("Batterie : %.0f %% → %.0f %%" % (100 * niveaux[0], 100 * niveaux[-1]))
    for type_, libelle in (("interruption_debut", "interruptions audio"), ("reprise_echec", "échecs de relance"),
                           ("capteur_trou", "trous dans les capteurs"), ("audio_trou", "trous dans le son"),
                           ("alerte_memoire", "alertes mémoire"), ("erreur", "erreurs")):
        n = len(s.evenements(type_))
        if n:
            r("%s : %d" % (libelle, n))
    for e in s.evenements("erreur")[:10]:
        r("   erreur : %s" % e.get("message"))
    if s.resume:
        for perte in s.resume.get("losses", [])[:15]:
            r("   perte : %s pendant %s (%s) — %s" % (temps_txt(perte["startUnix"] - s.resume["startUnix"]),
                                                     temps_txt(perte["duration"]), perte["what"], perte["cause"]))
    return r


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    rapport = verifier(sys.argv[1])
    texte = rapport.texte()
    print(texte)
    with open(os.path.join(sys.argv[1], "verification.txt"), "w", encoding="utf-8") as f:
        f.write(texte)
    with open(os.path.join(sys.argv[1], "verification.json"), "w", encoding="utf-8") as f:
        json.dump(rapport.resultats, f, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
