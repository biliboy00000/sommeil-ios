# Ciné — photos RAW au rendu pellicule cinéma

Appareil photo pour iPhone qui **ne passe pas par le traitement d'iOS** (Smart HDR, Deep Fusion,
renforcement de netteté, tone mapping local). Ciné récupère les données brutes du capteur (RAW Bayer)
et les développe lui-même avec un rendu **pellicule cinéma** :

- couleurs douces, saturation retenue, verts tirés vers l'olive ;
- peaux chaudes, hautes lumières légèrement chaudes, ombres légèrement froides ;
- noirs laiteux (jamais d'un noir pur) et hautes lumières qui s'arrondissent au lieu de couper ;
- halation (halo rouge orangé autour des lumières fortes) et léger voile lumineux ;
- grain fin, surtout dans les tons moyens ; vignettage léger.

Le viseur montre ce rendu **en direct**, avant chaque photo. Grain, halation, vignettage et format se
choisissent avant de déclencher (bouton en haut à gauche).

## Utilisation

- **Déclencher** : gros bouton blanc, ou boutons de volume (iOS 18 et plus).
- **Mise au point** : toucher le viseur. **Appui long** : exposition et mise au point verrouillées.
- **Objectifs** : pastilles 0,5× / 1× / 3× (selon l'iPhone), en bas du viseur. Ce sont les vrais
  objectifs, sans recadrage numérique.
- **Réglages manuels** (sous le viseur) : EXPO (correction ±3), ISO, VITESSE (dont 1/48 et 1/50, le
  flou de mouvement du cinéma), BALANCE (kelvins), MAP (mise au point manuelle). Touche un réglage, fais
  glisser la molette ; **AUTO** pour revenir en automatique. ISO et vitesse passent ensemble en manuel.
- **Format** (en haut à droite) : 4:3 (capteur entier), 3:2, 16:9, 1,85:1, 2,39:1 (Scope). Tiens
  l'iPhone à l'horizontale pour un cadre de cinéma.
- **FILM / BRUT** (en bas à droite) : compare l'aperçu avec et sans le rendu.
- **Vignette** (en bas à gauche) : les 30 dernières photos, avec zoom et partage. Toutes les photos
  sont aussi dans l'app **Photos** (HEIF 10 bits, Display P3), avec le RAW (DNG) joint si l'option
  « Garder aussi le RAW » est activée.

## Comment c'est fait

1. **Capture** : `AVCapturePhotoOutput` en RAW Bayer (pas ProRAW, qui est déjà traité), 12 Mpx,
   objectifs physiques. Si un objectif ne donne pas de RAW, Ciné prend une photo HEIF en mode rapide
   (le moins de traitement possible) et l'indique (« HEIF » en haut de l'écran).
2. **Développement** (`Developer.swift`) : `CIRAWFilter` sans courbe d'Apple (`boostAmount` 0), sans
   tone mapping local ni netteté, débruitage modéré selon l'ISO, correction de l'objectif. L'exposition
   est calée sur ce que montrait l'aperçu au moment de déclencher.
3. **Rendu** (`FilmKernels.metal`, mêmes formules que `Packages/FilmCore/Sources/FilmCore/FilmLook.swift`) :
   halation → courbe de pellicule canal par canal (sigmoïde en stops : gris moyen à 0,42, +2,5 stops à
   0,82, noirs à 0,03) → couleurs → grain → vignettage → recadrage au format.
4. **Enregistrement** : HEIF 10 bits dans Photos et dans l'app. Les données du capteur sont d'abord
   écrites sur l'iPhone : si l'app est fermée pendant le développement, la photo est reprise à la
   prochaine ouverture (rien n'est perdu).

`Packages/FilmCore` contient la version de référence du rendu et les calculs de l'appareil (formats,
crans d'ISO et de vitesse, orientation, objectifs), avec leurs tests (`swift test`, aussi sous Linux).

## Installation

Avec SideStore, comme Sommeil (voir `../INSTALLATION.md`) : la source « Sommeil et Ciné »
(`https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json`) propose les deux
apps. Ou directement le fichier : page **Releases** du dépôt, version « Ciné 1.0.N », `Cine.ipa`.

**Limite d'un identifiant Apple gratuit : 3 apps actives** (SideStore compte pour une). SideStore +
Sommeil + Ciné = 3 : il faut que l'ancienne Sommeil installée avec Sideloadly soit supprimée.

La compilation automatique est dans `.github/workflows/cine.yml`.
