# Format des données enregistrées par l'app Sommeil (version 1)

Chaque séance est un dossier `Seances/<date>_<heure>/` (par exemple `2026-10-10_23h14m05`, ou
`…_test` pour un test guidé). Il est visible dans l'app Fichiers (« Sur mon iPhone › Sommeil »)
et c'est ce dossier qui est envoyé tel quel au PC.

```
session.json        description de la séance (JSON)
journal.jsonl       événements : début, fin, interruptions, trous, marqueurs du test guidé…
horloge.jsonl       correspondance horloge des capteurs ↔ heure réelle, toutes les 10 s
etat.jsonl          état de l'iPhone toutes les 15 s (batterie, température, compteurs)
resume.json         bilan calculé à la fin (ou à la réouverture après un arrêt brutal)
capteurs/dm_00000.bin, dm_00001.bin…    mouvement fusionné, un fichier par 10 minutes
capteurs/acc_00000.bin…                 accéléromètre brut (si « capteurs bruts » activé)
capteurs/gyr_00000.bin…                 gyroscope brut (si « capteurs bruts » activé)
audio/a_00000.caf, a_00001.caf…         son, un fichier par minute
audio/index.jsonl                       début et durée de chaque fichier son
```

## Les deux horloges

- **uptime** : horloge des capteurs, en secondes depuis le démarrage de l'iPhone (`CMLogItem.timestamp`,
  `ProcessInfo.systemUptime`, et l'heure des blocs audio). Très régulière, c'est elle qui date les mesures.
- **unix** : heure réelle, en secondes depuis le 1er janvier 1970 (UTC).

`horloge.jsonl` donne des paires `{uptime, unix, continuous}` toutes les 10 secondes. Pour dater une
mesure : `unix ≈ unix_point + (uptime_mesure − uptime_point)` avec le point le plus proche.
`continuous` est une horloge qui compte aussi le temps de veille de l'iPhone (pour repérer une veille).

Le journal note au démarrage le décalage entre l'horloge des capteurs et celle du système
(`decalage_horloge_s`), pour vérifier qu'elles sont bien identiques.

## Fichiers binaires des capteurs (`capteurs/*.bin`)

Petit-boutiste (little-endian). Un en-tête de 64 octets, puis des enregistrements de taille fixe.
Un fichier coupé net par un arrêt brutal reste lisible : on ignore le dernier enregistrement incomplet.

En-tête :

| Octets | Type      | Contenu                                             |
|--------|-----------|-----------------------------------------------------|
| 0–8    | ASCII     | `SOMNBIN1`                                          |
| 8–10   | UInt16    | version du format (1)                               |
| 10–12  | UInt16    | flux : 1 = mouvement fusionné, 2 = accéléromètre brut, 3 = gyroscope brut |
| 12–14  | UInt16    | taille d'un enregistrement (octets)                 |
| 14–16  | UInt16    | réservé (0)                                         |
| 16–24  | Float64   | fréquence demandée (Hz), 100                        |
| 24–32  | Float64   | uptime à la création du fichier                     |
| 32–40  | Float64   | heure réelle (unix) à la création du fichier        |
| 40–44  | UInt32    | numéro du morceau (0, 1, 2…)                        |
| 44–64  | ASCII     | préfixe du flux (`dm`, `acc`, `gyr`), complété par des zéros |

Enregistrement : un `Float64` (uptime de la mesure, horodatage réel du capteur) puis des `Float32` :

| Flux | Taille | Valeurs |
|------|--------|---------|
| `dm` mouvement fusionné | 60 octets | `ux uy uz` accélération sans gravité (g) · `gx gy gz` gravité (g) · `rx ry rz` rotation corrigée (rad/s) · `qx qy qz qw` orientation (quaternion) |
| `acc` accéléromètre brut | 20 octets | `x y z` (g), gravité comprise |
| `gyr` gyroscope brut | 20 octets | `x y z` (rad/s), non corrigé |

Axes : ceux de l'iPhone (x vers la droite de l'écran, y vers le haut de l'écran, z sortant de l'écran).
Orientation : repère `xArbitraryZVertical` d'iOS (z vertical, sans boussole).
Fréquence demandée : 100 Hz, le maximum autorisé par iOS pour une app. La fréquence réellement
obtenue et sa régularité sont mesurées (journal : `stats_capteurs` ; bilan : `measuredRates`).
Aucune réduction de fréquence n'est faite, ni sur l'iPhone ni à l'import.

## Son (`audio/*.caf`)

Apple Lossless (ALAC) dans un conteneur CAF, 16 kHz, mono, 16 bits, un fichier par minute.
Si l'iPhone refuse l'ALAC, l'app passe en PCM 16 bits (même conteneur) et le note dans le journal.
Lecture sur PC : PyAV ou ffmpeg (`ffmpeg -i a_00000.caf a_00000.wav`).

`audio/index.jsonl` : une ligne à l'ouverture de chaque fichier (`complete: false`), une autre à sa
fermeture (`complete: true`, nombre d'échantillons `frames`). `startUptime` est l'heure du premier
échantillon, sur l'horloge des capteurs. Un fichier resté `complete: false` a été coupé par un arrêt
brutal et peut être illisible (au plus une minute perdue).

## Fichiers texte (JSON Lines)

Une ligne = un objet JSON. Une ligne coupée par un arrêt brutal est simplement ignorée.

- `journal.jsonl` : `{unix, uptime, type, message, values?, info?}`. Types principaux :
  `session_debut`, `session_fin`, `calibration_debut`, `calibration_fin`, `interruption_debut`,
  `interruption_fin`, `reprise_ok`, `reprise_echec`, `route_audio`, `reset_services_media`,
  `alerte_memoire`, `arriere_plan`, `premier_plan`, `app_fermee`, `capteur_trou`
  (`values.debut_unix`, `values.duree_s`, `info.flux`), `audio_trou`, `marqueur`
  (test guidé, `info.marqueur`), `erreur`, `thermique`, `batterie`, `stats_capteurs`.
- `etat.jsonl` : `{unix, uptime, battery (0–1), batteryState, thermal, lowPowerMode, freeDiskMB,
  samples {dm, acc, gyr}, audioSeconds, audioRunning}`. La dernière ligne indique jusqu'à quand
  l'app tournait. La température exacte n'est pas accessible aux apps : `thermal` vaut
  `normal`, `eleve`, `serieux` ou `critique`.

## session.json

Identifiant, type (`nuit`, `test_guide`), appareil, version d'iOS et de l'app, début et fin
(uptime et unix), `endedNormally` (faux si l'app a été arrêtée par iOS), flux enregistrés, format
audio, calibration (`gravity` : vecteur gravité moyen sur le dos, normalisé ; `movement` : agitation
en g), date d'expiration de l'installation, test de l'API haute fréquence d'Apple.

- `calibrationMode` : `guidee` (30 s sur le dos au début, avec la voix) ou `automatique` (nuit au
  début différé : l'app examine des tranches de 30 s et retient la première calme, à plat et écran vers
  le haut ; en attendant, ou si aucune ne convient, elle garde la meilleure tranche vue).
- `delayedStart` (seulement si un délai a été choisi) : `{requestedUnix, delayMinutes, source}`.
  `requestedUnix` est l'heure du « Oui », `source` vaut `notification` ou `app`. Pendant l'attente,
  le micro tourne pour garder l'app active mais rien n'est écrit : la séance commence à `startUnix`.
  Le journal le reprend dans `session_debut` (`info.debut_differe`, `values.attente_min`,
  `values.demande_unix`).
