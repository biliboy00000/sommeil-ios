# -*- coding: utf-8 -*-
"""
Analyse d'un scan Sonar (dossier ou .zip exporté par l'app).

    python3 analyse/analyser_scan.py <scan.zip | dossier> [--sortie dossier] [--voxel 0.05] [--portee 4]

Étapes :
  1. filtre adapté (corrélation avec le chirp de référence) sur tout l'enregistrement ;
  2. repérage du son direct de chaque chirp = instant d'émission (temps zéro) ;
  3. profil d'échos (intensité selon la distance) par chirp, nettoyé de ce qui est fixe par rapport au téléphone ;
  4. position/orientation du téléphone à chaque chirp (poses ARKit interpolées) ;
  5. rétroprojection : chaque profil « vote » pour les voxels situés à la bonne distance ;
  6. images + nuage de points (.ply), et comparaison au maillage LiDAR s'il existe.
"""
import argparse
import json
import os
import sys
import tempfile
import zipfile

import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.spatial.transform import Rotation, Slerp

C = 343.0


# ---------------------------------------------------------------- lecture

def ouvrir(chemin):
    if zipfile.is_zipfile(chemin):
        dest = tempfile.mkdtemp(prefix="scan_")
        with zipfile.ZipFile(chemin) as z:
            z.extractall(dest)
        # le zip contient un dossier racine
        for racine, _, fichiers in os.walk(dest):
            if "meta.json" in fichiers:
                return racine
        raise SystemExit("meta.json introuvable dans le zip")
    return chemin


def lire_csv(chemin):
    with open(chemin, encoding="utf-8") as f:
        entete = f.readline().strip().split(",")
        lignes = [l.strip().split(",") for l in f if l.strip()]
    return entete, lignes


def charger(dossier):
    meta = json.load(open(os.path.join(dossier, "meta.json"), encoding="utf-8"))
    sr, audio = wavfile.read(os.path.join(dossier, "audio.wav"))
    audio = audio.astype(np.float64)
    if audio.ndim == 1:
        audio = audio[:, None]
    _, ref = wavfile.read(os.path.join(dossier, "reference.wav"))
    ref = ref.astype(np.float64)

    _, t = lire_csv(os.path.join(dossier, "audio_temps.csv"))
    t = np.array([[float(a), float(b)] for a, b, *_ in t])
    ok = t[:, 1] > 0
    temps = t[ok]  # (indice d'échantillon, temps hôte)

    poses = None
    p = os.path.join(dossier, "poses.csv")
    if os.path.exists(p):
        entete, lignes = lire_csv(p)
        if lignes:
            num = np.array([[float(x) for x in l[:8]] for l in lignes])
            etat = np.array([l[8] for l in lignes])
            poses = {"t": num[:, 0], "pos": num[:, 1:4], "quat": num[:, 4:8], "etat": etat}

    maillage = None
    m = os.path.join(dossier, "maillage_lidar.obj")
    if os.path.exists(m):
        v = [list(map(float, l.split()[1:4])) for l in open(m) if l.startswith("v ")]
        maillage = np.array(v) if v else None
    return meta, sr, audio, ref, temps, poses, maillage


# ---------------------------------------------------------------- échos

def profils(audio, ref, sr, periode, portee):
    """Renvoie (indices du son direct, profils [chirp, retard], retard max)."""
    x = audio.mean(axis=1)
    # passe-bande autour du chirp pour éliminer bruit grave et voix
    f0, f1 = 16500, min(23500, sr / 2 - 100)
    sos = signal.butter(6, [f0, f1], "band", fs=sr, output="sos")
    xf = signal.sosfiltfilt(sos, x)
    corr = signal.fftconvolve(xf, ref[::-1], mode="full")[len(ref) - 1:]
    env = np.abs(signal.hilbert(corr))

    lag_max = min(periode - 1, int(2 * portee / C * sr))
    n = len(env) // periode
    directs, rangs = [], []
    # repère du son direct : maximum de chaque période, stabilisé
    precedent = None
    pics = np.array([env[k * periode:(k + 1) * periode].max() for k in range(n)])
    seuil = 0.1 * np.median(pics) if n else 0
    for k in range(n - 1):
        bloc = env[k * periode:(k + 1) * periode]
        if bloc.max() < seuil:  # pas de chirp (début/fin d'enregistrement, coupure)
            precedent = None
            continue
        i = int(np.argmax(bloc))
        if precedent is not None and bloc[precedent] > 0.5 * bloc[i]:
            i = precedent
        precedent = i
        d = k * periode + i
        if d + lag_max >= len(env):
            break
        directs.append(d)
        rangs.append(env[d:d + lag_max] / (env[d] + 1e-12))
    return np.array(directs), np.array(rangs), lag_max, env


def nettoyer(rangs, sr, proche=0.45):
    """Retire, près du téléphone seulement, ce qui ne bouge pas avec lui (son direct, main, coque).
    Au-delà on garde tout : le sol et le plafond restent à distance constante quand on marche."""
    n = min(rangs.shape[1], int(2 * proche / C * sr))
    out = rangs.copy()
    med = np.median(rangs[:, :n], axis=0)
    out[:, :n] = np.clip(rangs[:, :n] - 1.5 * med, 0, None)
    # bord adouci pour ne pas créer de marche artificielle
    m = int(0.1 * n)
    if m > 1:
        out[:, n - m:n] = np.maximum(out[:, n - m:n], rangs[:, n - m:n] * np.linspace(0, 1, m))
    return out


# ---------------------------------------------------------------- poses

def temps_hote(indices, temps):
    return np.interp(indices, temps[:, 0], temps[:, 1])


def poses_aux_instants(poses, t):
    ok = np.isin(poses["etat"], ["normal"])
    pt, pp, pq = poses["t"][ok], poses["pos"][ok], poses["quat"][ok]
    if len(pt) < 2:
        return None, None, np.zeros(len(t), bool)
    dans = (t >= pt[0]) & (t <= pt[-1])
    tc = np.clip(t, pt[0], pt[-1])
    pos = np.stack([np.interp(tc, pt, pp[:, i]) for i in range(3)], axis=1)
    rot = Slerp(pt, Rotation.from_quat(pq))(tc)
    return pos, rot, dans


# ---------------------------------------------------------------- rétroprojection

def retroprojeter(pos, rot, rangs, sr, voxel, portee, axe=(0, 0, -1), directivite=1.0):
    lo = pos.min(axis=0) - portee
    hi = pos.max(axis=0) + portee
    lo[1] = max(lo[1], pos[:, 1].min() - 2.5)
    hi[1] = min(hi[1], pos[:, 1].max() + 2.0)
    axes = [np.arange(lo[i], hi[i], voxel) for i in range(3)]
    gx, gy, gz = np.meshgrid(*axes, indexing="ij")
    pts = np.stack([gx.ravel(), gy.ravel(), gz.ravel()], axis=1)
    acc = np.zeros(len(pts))
    cnt = np.zeros(len(pts))
    lag = np.arange(rangs.shape[1])
    dist_lag = lag * C / sr / 2
    axe = np.asarray(axe, float)
    for k in range(len(pos)):
        d = pts - pos[k]
        r = np.linalg.norm(d, axis=1)
        dans = (r > 0.15) & (r < dist_lag[-1])
        if not dans.any():
            continue
        v = np.interp(r[dans], dist_lag, rangs[k])
        poids = np.ones(dans.sum())
        if directivite > 0:
            direction = rot[k].apply(axe)
            cosang = (d[dans] @ direction) / r[dans]
            poids = (0.5 + 0.5 * cosang) ** directivite
        # compensation de l'atténuation géométrique (aller-retour)
        acc[dans] += v * poids * r[dans] ** 2
        cnt[dans] += poids
    img = np.where(cnt > 0, acc / np.maximum(cnt, 1e-9), 0)
    return img.reshape(gx.shape), axes


def fibonacci_sphere(n):
    i = np.arange(n) + 0.5
    phi = np.arccos(1 - 2 * i / n)
    theta = np.pi * (1 + 5 ** 0.5) * i
    return np.stack([np.cos(theta) * np.sin(phi), np.cos(phi), np.sin(theta) * np.sin(phi)], axis=1)


def chercher_plans(pos, rot, rangs, sr, portee, axe=(0, 0, -1), directivite=1.0,
                   n_normales=2500, pas=0.02, max_plans=8):
    """Transformée de Hough des plans : un mur réfléchit comme un miroir, son écho arrive à la distance
    perpendiculaire téléphone → mur. Pour chaque plan candidat (normale n, distance ρ au centre du trajet),
    on moyenne l'intensité des profils à la distance prédite ρ − n·(p − centre)."""
    normales = fibonacci_sphere(n_normales)
    rho = np.arange(0.2, portee, pas)
    centre = pos.mean(axis=0)
    dist_lag = np.arange(rangs.shape[1]) * C / sr / 2
    acc = np.zeros((len(normales), len(rho)))
    poids_tot = np.zeros_like(acc)
    axe = np.asarray(axe, float)
    # on retire le plancher de bruit de chaque profil : sinon la compensation ×d fait « gagner » le bruit au loin
    loin = dist_lag > 0.5
    plancher = np.median(rangs[:, loin], axis=1, keepdims=True) if loin.any() else 0
    rangs = np.clip(rangs - 2.0 * plancher, 0, None)
    for k in range(len(pos)):
        proj = normales @ (pos[k] - centre)              # (N,)
        d = rho[None, :] - proj[:, None]                  # distance perpendiculaire
        ok = (d > 0.15) & (d < dist_lag[-1])
        v = np.zeros_like(d)
        v[ok] = np.interp(d[ok], dist_lag, rangs[k]) * d[ok]   # compense l'atténuation 1/(2d)
        if directivite > 0:
            g = (0.5 + 0.5 * normales @ rot[k].apply(axe)) ** directivite
        else:
            g = np.ones(len(normales))
        w = ok * g[:, None]
        acc += v * g[:, None]
        poids_tot += w
    score = np.where(poids_tot > 0.05 * len(pos), acc / np.maximum(poids_tot, 1e-9), 0)

    plans = []
    s = score.copy()
    ref = s.max()
    for _ in range(max_plans):
        i, j = np.unravel_index(np.argmax(s), s.shape)
        if s[i, j] < 0.2 * ref or s[i, j] <= 0:
            break
        n = normales[i]
        plans.append({"normale": n.round(3).tolist(), "distance_au_centre_m": float(rho[j]),
                      "score": float(s[i, j] / ref)})
        proche = (normales @ n) > np.cos(np.radians(25))
        s[np.ix_(proche, np.abs(rho - rho[j]) < 0.4)] = 0
        s[(normales @ n) > np.cos(np.radians(8)), :] = 0
    return plans, centre, score, normales, rho


# ---------------------------------------------------------------- sorties

def ecrire_ply(chemin, pts, val):
    with open(chemin, "w") as f:
        f.write("ply\nformat ascii 1.0\nelement vertex %d\nproperty float x\nproperty float y\nproperty float z\n"
                "property float intensite\nend_header\n" % len(pts))
        for p, v in zip(pts, val):
            f.write("%.3f %.3f %.3f %.4f\n" % (p[0], p[1], p[2], v))


def analyser(chemin, sortie, voxel=0.05, portee=4.0, directivite=1.0):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    dossier = ouvrir(chemin)
    meta, sr, audio, ref, temps, poses, maillage = charger(dossier)
    os.makedirs(sortie, exist_ok=True)
    sig = meta.get("signal", {})
    periode = int(sig.get("echantillons_periode", int(0.05 * sr)))
    mode = meta.get("mode", "balayage")
    rapport = {"mode": mode, "duree_s": len(audio) / sr, "frequence": sr, "canaux": audio.shape[1],
               "lidar": meta.get("lidar"), "appareil": meta.get("appareil")}

    if sig.get("type") != "chirp_lineaire":
        rapport["note"] = "Scan acoustique (balayage audible) : analyse de réverbération à faire séparément."
        json.dump(rapport, open(os.path.join(sortie, "rapport.json"), "w"), indent=2, ensure_ascii=False)
        return rapport

    directs, rangs, lag_max, env = profils(audio, ref, sr, periode, portee)
    propres = nettoyer(rangs, sr)
    dist = np.arange(lag_max) * C / sr / 2
    plancher = np.median(rangs[:, -lag_max // 5:]) if len(rangs) else 0
    rapport.update({
        "chirps": int(len(directs)),
        "plancher_bruit_dB": float(20 * np.log10(plancher + 1e-12)),
        "regularite_son_direct_ech": float(np.std(np.diff(directs) - periode)) if len(directs) > 2 else None,
    })

    # échogramme brut et nettoyé
    fig, ax = plt.subplots(1, 2, figsize=(13, 6), sharey=True)
    for a, data, titre in [(ax[0], rangs, "brut"), (ax[1], propres, "nettoyé (fixe/téléphone retiré)")]:
        db = 20 * np.log10(data + 1e-6)
        a.imshow(db, aspect="auto", origin="lower", cmap="magma", vmin=-60, vmax=-10,
                 extent=[0, dist[-1], 0, len(data) * periode / sr])
        a.set_xlabel("distance (m)")
        a.set_title("Échogramme " + titre)
    ax[0].set_ylabel("temps (s)")
    plt.tight_layout()
    plt.savefig(os.path.join(sortie, "echogramme.png"), dpi=90)
    plt.close()

    # profil moyen
    plt.figure(figsize=(10, 4))
    plt.plot(dist, 20 * np.log10(np.median(rangs, axis=0) + 1e-9), label="médiane brute")
    plt.plot(dist, 20 * np.log10(np.percentile(propres, 90, axis=0) + 1e-9), label="90e centile nettoyé")
    plt.xlabel("distance (m)"); plt.ylabel("dB / son direct"); plt.legend(); plt.grid(alpha=.3)
    plt.tight_layout(); plt.savefig(os.path.join(sortie, "profil.png"), dpi=90); plt.close()

    if poses is None:
        rapport["note"] = "Pas de poses : pas de reconstruction 3D."
        json.dump(rapport, open(os.path.join(sortie, "rapport.json"), "w"), indent=2, ensure_ascii=False)
        return rapport

    t = temps_hote(directs, temps)
    pos, rot, dans = poses_aux_instants(poses, t)
    rapport["suivi_normal_pct"] = float(100 * np.mean(poses["etat"] == "normal"))
    rapport["decalage_audio_poses_s"] = float(t[0] - poses["t"][0]) if len(t) else None
    if pos is None or dans.sum() < 5:
        rapport["note"] = "Suivi ARKit insuffisant pendant le scan."
        json.dump(rapport, open(os.path.join(sortie, "rapport.json"), "w"), indent=2, ensure_ascii=False)
        return rapport
    pos, propres_ok = pos[dans], propres[dans]
    rot = rot[np.where(dans)[0]]
    rapport["trajet_m"] = float(np.sum(np.linalg.norm(np.diff(pos, axis=0), axis=1)))
    rapport["etendue_m"] = (pos.max(0) - pos.min(0)).round(2).tolist()

    # au plus ~500 chirps pour garder des calculs rapides
    pas_c = max(1, len(pos) // 500)
    pos_d, rot_d, pr_d = pos[::pas_c], rot[np.arange(0, len(pos), pas_c)], propres_ok[::pas_c]

    plans, centre, _, _, _ = chercher_plans(pos_d, rot_d, pr_d, sr, portee, directivite=directivite)
    for p in plans:
        n = np.array(p["normale"])
        p["equation"] = "n·x = %.3f" % (p["distance_au_centre_m"] + n @ centre)
        p["type"] = ("sol" if n[1] < -0.8 else "plafond" if n[1] > 0.8 else
                     "mur" if abs(n[1]) < 0.3 else "incliné")
    rapport["plans"] = plans

    vol, axes = retroprojeter(pos_d, rot_d, pr_d, sr, voxel, portee, directivite=directivite)
    seuil = np.percentile(vol[vol > 0], 99.0) if (vol > 0).any() else 0
    idx = np.argwhere(vol >= seuil)
    pts = np.stack([axes[i][idx[:, i]] for i in range(3)], axis=1) if len(idx) else np.zeros((0, 3))
    ecrire_ply(os.path.join(sortie, "nuage_sonar.ply"), pts, vol[vol >= seuil])
    np.savez_compressed(os.path.join(sortie, "volume.npz"), volume=vol.astype(np.float32),
                        x=axes[0], y=axes[1], z=axes[2], trajectoire=pos)
    rapport["points_sonar"] = int(len(pts))

    # vues : dessus (x,z) et côté (x,y)
    fig, ax = plt.subplots(1, 2, figsize=(14, 6.5))
    vues = [(ax[0], vol.max(axis=1).T, axes[0], axes[2], (0, 2), "Vue de dessus (x, z)"),
            (ax[1], vol.max(axis=2).T, axes[0], axes[1], (0, 1), "Vue de côté (x, y = hauteur)")]
    for a, img, ha, va, (i, j), titre in vues:
        a.imshow(img, origin="lower", cmap="inferno", extent=[ha[0], ha[-1], va[0], va[-1]],
                 vmin=0, vmax=np.percentile(img, 99.5) + 1e-12, aspect="equal")
        if maillage is not None:
            m = maillage[::max(1, len(maillage) // 20000)]
            a.scatter(m[:, i], m[:, j], s=0.3, c="cyan", alpha=0.25, label="LiDAR")
        a.plot(pos[:, i], pos[:, j], "w-", lw=1, label="trajet")
        # plans détectés : trace de n·x = c dans cette vue (si le plan y est vu par la tranche)
        for p in plans:
            n = np.array(p["normale"]); c = float(p["equation"].split("=")[1])
            k = 3 - i - j
            if abs(n[k]) > 0.5:
                continue
            xs = np.linspace(ha[0], ha[-1], 200)
            if abs(n[j]) > 1e-3:
                ys = (c - n[i] * xs - n[k] * centre[k]) / n[j]
                a.plot(xs, ys, "--", color="lime", lw=1.2, alpha=0.4 + 0.6 * p["score"])
            else:
                a.axvline((c - n[k] * centre[k]) / n[i], ls="--", color="lime", lw=1.2, alpha=0.4 + 0.6 * p["score"])
        a.set_xlim(ha[0], ha[-1]); a.set_ylim(va[0], va[-1])
        a.set_title(titre); a.set_xlabel("m")
        a.legend(loc="upper right", fontsize=8)
    plt.tight_layout(); plt.savefig(os.path.join(sortie, "vues_3d.png"), dpi=90); plt.close()

    if maillage is not None and len(pts):
        from scipy.spatial import cKDTree
        arbre = cKDTree(maillage)
        d, _ = arbre.query(pts)
        rapport["ecart_sonar_lidar_median_m"] = float(np.median(d))
        rapport["sonar_a_moins_de_10cm_du_lidar_pct"] = float(100 * np.mean(d < 0.10))

    json.dump(rapport, open(os.path.join(sortie, "rapport.json"), "w"), indent=2, ensure_ascii=False)
    return rapport


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("scan")
    ap.add_argument("--sortie", default=None)
    ap.add_argument("--voxel", type=float, default=0.05)
    ap.add_argument("--portee", type=float, default=4.0)
    ap.add_argument("--directivite", type=float, default=1.0)
    a = ap.parse_args()
    sortie = a.sortie or os.path.splitext(os.path.basename(a.scan.rstrip("/")))[0] + "_analyse"
    r = analyser(a.scan, sortie, a.voxel, a.portee, a.directivite)
    print(json.dumps(r, indent=2, ensure_ascii=False))
