# Ciné — appareil photo et caméra au rendu pellicule cinéma

Appareil photo et caméra pour iPhone qui **ne passent pas par le traitement d'iOS** (Smart HDR, Deep Fusion,
renforcement de netteté, tone mapping local). En photo, Ciné récupère les données brutes du capteur (RAW
Bayer) et les développe lui-même ; en vidéo, chaque image passe dans le même rendu avant d'être enregistrée.
Le viseur montre ce rendu **en direct**.

## Pellicules

| Code | Pellicule | Rendu |
|---|---|---|
| 250D | Pellicule cinéma | Couleurs douces, peaux chaudes, noirs laiteux (le rendu d'origine) |
| 500T | Nuit tungstène | Froide, ombres bleu-vert, halation forte, plus de grain |
| ETR | Eterna | Contraste bas, couleurs retenues, verts éteints |
| BBP | Sans blanchiment | Couleurs lavées, contraste fort, noirs denses |
| N&B | Noir et blanc | Contraste franc, grain présent (type Double-X) |

Bouton « pellicule » en bas à droite : bandeau des pellicules, et « maintenir pour comparer » avec l'image brute.

**Effets optiques** (Réglages) : grain (sans, fin, marqué), halation (halo rouge orangé autour des lumières),
diffusion façon filtre Black Pro-Mist (1/8, 1/4, 1/2), flares anamorphiques (traits bleutés depuis les
lumières vives), vignettage.

## Vidéo cinéma

- 24, 25 ou 30 images par seconde, en HD ou en 4K, et **ralenti** ×2 (48 → 24) ou ×2,5 (60 → 24).
- **Obturateur en degrés** : 180° par défaut (1/48 s à 24 i/s, le flou de mouvement du cinéma), l'ISO
  s'adapte tout seul à la lumière. Ou tout en manuel (ISO, obturateur), ou tout en automatique.
- Formats 16:9, 1,85:1, 2,39:1 (Scope), 4:3, 3:2 : l'image enregistrée a vraiment ces proportions.
- Stabilisation cinéma, son du micro (avec vumètre), code temporel, cadre rouge pendant l'enregistrement.
- Fichier HEVC (BT.709) avec le rendu pellicule déjà appliqué, rangé dans Photos (et les 3 dernières vidéos
  dans Ciné).
- En France, sous des lampes, 25 i/s évite le scintillement.

## Visée

Zébras (zones qui seront blanches), focus peaking (contours nets en ambre), histogramme, niveau, grille des
tiers. Ces outils n'apparaissent jamais sur les photos ni les vidéos.

## Utilisation

- **PHOTO / VIDÉO** au-dessus du déclencheur (ou glisser dessus).
- **Déclencher / filmer** : gros bouton, ou boutons de volume (iOS 18 et plus). **Retardateur** 3 ou 10 s
  (bouton en haut à gauche).
- **Mise au point** : toucher le viseur. **Appui long** : exposition et mise au point verrouillées.
- **Objectifs** : pastilles 0,5× / 1× / 3× (les vrais objectifs, sans recadrage numérique).
- **Réglages manuels** sous le viseur : EXPO, ISO, VITESSE (ou OBTURATEUR en vidéo), BALANCE, MAP.
  Touche un réglage, fais glisser la molette ; **AUTO** pour revenir en automatique.
- **Format** en haut à droite (retenu séparément en photo et en vidéo). Tiens l'iPhone à l'horizontale pour
  un cadre de cinéma.
- **Vignette** en bas à gauche : les dernières photos et vidéos (zoom, lecture, partage, retrait de Ciné).
- **Lieu** (option) : ajouté aux photos et aux vidéos.

## Comment c'est fait

1. **Photo** : `AVCapturePhotoOutput` en RAW Bayer (pas ProRAW), 12 Mpx. Développement avec `CIRAWFilter`
   sans courbe d'Apple (`boostAmount` 0), débruitage modéré selon l'ISO ; l'exposition est calée sur ce que
   montrait l'aperçu. Si un objectif ne donne pas de RAW, photo HEIF en mode rapide (« HEIF » à l'écran).
2. **Vidéo** : format du capteur choisi pour la définition et la cadence, sans HDR vidéo ni courbe globale ;
   chaque image est rendue (`FrameProcessor.swift`) puis encodée par `AVAssetWriter` (`VideoRecorder.swift`).
3. **Rendu** (`FilmKernels.metal`, mêmes formules que `Packages/FilmCore`) : effets optiques en lumière
   linéaire → courbe de la pellicule canal par canal → couleurs → grain → vignettage.
4. **Enregistrement** : photos en HEIF 10 bits (Display P3). Les données du capteur sont d'abord écrites sur
   l'iPhone : si l'app est fermée pendant un développement, la photo est reprise à la prochaine ouverture.

`Packages/FilmCore` contient la version de référence des pellicules et tous les calculs (formats, crans,
obturateur en degrés, cadences, choix du format vidéo, ISO automatique à obturateur fixe, niveau, code
temporel), avec leurs tests (`swift test`, aussi sous Linux).

Journal de l'app : app Fichiers › Sur mon iPhone › Ciné › journal.txt.

## Installation

Avec SideStore, comme Sommeil (voir `../INSTALLATION.md`) : la source « Sommeil et Ciné »
(`https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json`) propose les deux
apps. Ou directement le fichier : page **Releases** du dépôt, version « Ciné 1.1.N », `Cine.ipa`.

**Limite d'un identifiant Apple gratuit : 3 apps actives** (SideStore compte pour une). SideStore +
Sommeil + Ciné = 3.

La compilation automatique est dans `.github/workflows/cine.yml`.
