# -*- coding: utf-8 -*-
"""
Fabrique un faux scan (même format que l'app) dans une pièce « boîte », pour tester l'analyse sans iPhone.

    python3 analyse/simuler_scan.py <dossier_sortie> [--mode balayage|phare]
"""
import argparse
import json
import os

import numpy as np
from scipy.io import wavfile
from scipy.spatial.transform import Rotation

C = 343.0
SR = 48000
# Pièce : x de -2 à 2.2 m, y (hauteur) de -1.2 à 1.3 m, z de -2.5 à 1.5 m (repère ARKit, téléphone au départ en 0).
MURS = [(0, -2.0), (0, 2.2), (1, -1.2), (1, 1.3), (2, -2.5), (2, 1.5)]
OBJETS = [np.array([0.8, -0.45, -1.2])]  # un coin de table, petit réflecteur


def chirp(sr=SR):
    n = int(sr * 0.010)
    t = np.arange(n) / sr
    k = 4000 / (n / sr)
    s = np.sin(2 * np.pi * (18000 * t + 0.5 * k * t * t))
    fade = n // 5
    w = np.ones(n)
    w[:fade] = 0.5 - 0.5 * np.cos(np.pi * np.arange(fade) / fade)
    w[-fade:] = w[:fade][::-1]
    return (s * w).astype(np.float32)


def simuler(sortie, mode="balayage", duree=20.0, seed=1):
    rng = np.random.default_rng(seed)
    os.makedirs(sortie, exist_ok=True)
    ref = chirp()
    periode = int(0.05 * SR)
    n_chirps = int(duree / 0.05)
    audio = np.zeros(n_chirps * periode + SR, np.float64)
    latence = 37  # échantillons entre émission et son direct
    t0_hote = 1000.0

    poses_lignes = []
    for k in range(n_chirps):
        u = k / n_chirps
        if mode == "balayage":
            pos = np.array([1.2 * np.sin(2 * np.pi * u), 0.15 * np.sin(6 * np.pi * u), -0.8 * u + 0.3 * np.cos(2 * np.pi * u)])
            yaw = 2 * np.pi * u
        else:
            pos = np.zeros(3)
            yaw = 2 * np.pi * u * 1.5
        rot = Rotation.from_euler("y", yaw)
        debut = k * periode
        # son direct
        audio[debut + latence:debut + latence + len(ref)] += 0.6 * ref
        # échos des murs (réflexion spéculaire : distance perpendiculaire)
        cible = []
        for axe, plan in MURS:
            d = abs(plan - pos[axe])
            n = np.zeros(3); n[axe] = np.sign(plan - pos[axe])
            gain = 0.5 + 0.5 * (rot.apply([0, 0, -1]) @ n)  # directivité vers l'arrière du téléphone
            cible.append((2 * d, 0.35 * gain / (2 * d)))
        for o in OBJETS:
            d = np.linalg.norm(o - pos)
            cible.append((2 * d, 0.05 / (2 * d) ** 2))
        for chemin, a in cible:
            i = debut + latence + int(round(chemin / C * SR))
            if i + len(ref) < len(audio):
                audio[i:i + len(ref)] += a * ref
        q = rot.as_quat()
        for j in range(3):  # 60 poses/s ≈ 3 par chirp
            t = t0_hote + (debut + j * periode / 3) / SR
            poses_lignes.append("%.6f,%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f,normal" % (t, *pos, *q))

    # bruit + un peu de réverbération diffuse
    audio += rng.normal(0, 2e-4, len(audio))
    wavfile.write(os.path.join(sortie, "audio.wav"), SR, audio.astype(np.float32))
    wavfile.write(os.path.join(sortie, "reference.wav"), SR, ref)
    with open(os.path.join(sortie, "audio_temps.csv"), "w") as f:
        f.write("premier_echantillon,temps_hote_s,nb_echantillons\n")
        for i in range(0, len(audio), 2048):
            f.write("%d,%.9f,%d\n" % (i, t0_hote + i / SR, 2048))
    with open(os.path.join(sortie, "poses.csv"), "w") as f:
        f.write("t,tx,ty,tz,qx,qy,qz,qw,suivi\n" + "\n".join(poses_lignes) + "\n")
    meta = {"format": "sonar-scan-1", "mode": mode, "lidar": False, "appareil": "simulation",
            "signal": {"type": "chirp_lineaire", "echantillons_periode": periode, "echantillons_chirp": len(ref)}}
    json.dump(meta, open(os.path.join(sortie, "meta.json"), "w"), indent=2)
    return sortie


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("sortie")
    ap.add_argument("--mode", default="balayage")
    a = ap.parse_args()
    print(simuler(a.sortie, a.mode))
