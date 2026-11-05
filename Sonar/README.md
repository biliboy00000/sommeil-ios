# Sonar

App iPhone qui scanne une pièce **avec le son** : le haut-parleur émet des chirps quasi inaudibles
(17,5–20 kHz), les micros enregistrent les échos, et ARKit donne la position du téléphone à chaque chirp.
Le LiDAR est optionnel et sert seulement de **référence** pour vérifier le sonar.

Cette première version est une **app de capture** : elle enregistre tout proprement, affiche les échos
en direct, et exporte un `.zip`. La reconstruction 3D se fait pour l'instant hors ligne
(`Sonar/analyse/analyser_scan.py`).

## Installer (SideStore)

Sonar est compilé sur GitHub à chaque modification du dossier `Sonar/` (`.github/workflows/sonar.yml`)
et ajouté à la même source SideStore que Sommeil et Ciné :
SideStore › Sources › « Sommeil, Ciné et Sonar » › Sonar. Ou le fichier `Sonar.ipa` de la dernière
version « Sonar 0.1.N » dans la page Releases du dépôt.

Un identifiant Apple gratuit permet **3 apps actives** (SideStore compris) : désactive Ciné
(SideStore › My Apps › Ciné › Désactiver) pour faire de la place, ses données sont gardées.

## Utiliser

| Mode | Geste | Ce que ça donne |
|---|---|---|
| **Phare** | Reste sur place, pivote lentement le téléphone | Distances des surfaces, direction floue |
| **Balayage** | Déplace-toi lentement (vers un mur et retour, tour de la pièce) | Murs, sol, plafond positionnés en 3D |
| **Acoustique** | Téléphone immobile, balayage audible 40 Hz → 20 kHz | Réverbération, résonances |

- **Cadence** : 40, 20 ou 10 chirps par seconde (portée 4, 9 ou 17 m).
- **Micro** : bas, avant, arrière, ou stéréo si l'iPhone le permet.
- **LiDAR (référence)** : enregistre aussi le maillage LiDAR (`maillage_lidar.obj`) pour comparer.

Liste des scans (icône en bas à gauche) › toucher un scan › partager le `.zip`.
Les scans sont aussi dans l'app Fichiers › Sur mon iPhone › Sonar.

## Contenu d'un scan

| Fichier | Contenu |
|---|---|
| `audio.wav` | Micro brut, 48 kHz, 32 bits flottants, mode « mesure » (sans traitement iOS) |
| `audio_temps.csv` | Heure exacte de chaque tampon audio (même horloge qu'ARKit) |
| `reference.wav` | Le chirp (ou balayage) émis, pour le filtre adapté |
| `poses.csv` | Pose ARKit à 60 Hz : position (m), quaternion, état du suivi |
| `mouvement.csv` | Capteurs de mouvement à 100 Hz |
| `maillage_lidar.obj` | Maillage LiDAR (si activé) |
| `meta.json` | Réglages, micro utilisé, latences, appareil |

## Analyser

```bash
pip install numpy scipy matplotlib
python3 Sonar/analyse/analyser_scan.py scan.zip
```

Sorties : `echogramme.png`, `profil.png`, `vues_3d.png`, `nuage_sonar.ply`, `rapport.json`
(dont les **plans détectés** : murs, sol, plafond, et l'écart au LiDAR si présent).

`analyse/simuler_scan.py` fabrique un faux scan dans une pièce connue pour tester l'analyse.
Sur la simulation, en mode balayage, les 6 faces de la pièce sont retrouvées à ±1 cm.
