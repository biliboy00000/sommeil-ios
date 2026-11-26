# Gadget

Une seule app qui réunit les gadgets, pour n'occuper qu'**une place** dans SideStore
(un identifiant Apple gratuit n'en permet que 3, SideStore compris).

| Gadget | Dossier | Écran ouvert |
|---|---|---|
| **Sommeil** : nuit, cœur et respiration | `App/` et `Packages/SleepCore/` | `SommeilRoot` |
| **Ciné** : photos et vidéos au rendu pellicule | `Cine/` | `CineRoot` |
| **Sonar** : scanner une pièce avec le son | `Sonar/` | `SonarRoot` |
| **Télécommande** : piloter le PC, et son son sur le téléphone | `Telecommande/` | `TeleRoot` |

L'accueil montre la grille des gadgets. Un gadget s'ouvre en plein écran ; le bouton
« grille » en haut à gauche ramène à l'accueil et l'arrête (caméra, micro, capteurs).
Dans Sommeil, c'est l'onglet « Gadgets » en bas ; il n'apparaît pas pendant une nuit. Le modèle de
Sommeil reste en mémoire après le retour à la grille (rappel du soir, analyse des nuits), et la
réponse au rappel « Démarrer la nuit ? » ouvre directement Sommeil.

Sommeil dans Gadget n'a pas l'extension de notification de l'app seule (la barre de 0 à 2 h sur
l'appui long) : elle prendrait une place de plus dans SideStore. « Oui… » ouvre la même barre dans
l'app. Réglages › « Reprendre les nuits de l'app Sommeil » copie les nuits de l'app seule.

## Comment c'est construit

- Le code de chaque gadget reste dans son dossier et sert aussi à son app seule
  (`Cine/project.yml`, `Sonar/project.yml`, compilées pour vérification).
- Le point d'entrée de chaque app seule (`@main`) est rangé à part, dans `App/Entry/`,
  que Gadget n'inclut pas.
- `Shared/` contient ce qui est commun : le bouton de retour (`GadgetExitButton`), qui n'apparaît
  que dans Gadget.

## Ajouter un gadget

1. Créer son dossier à la racine (`MonGadget/App/Sources`, `MonGadget/App/Entry` pour son `@main`).
2. Lui donner une vue racine qui crée son modèle et l'arrête dans `onDisappear` (voir `SonarRoot`).
3. Mettre `GadgetExitButton()` dans sa barre du haut.
4. Dans `Gadget/project.yml` : ajouter `../MonGadget/App/Sources` aux sources et ses autorisations dans `info`.
5. Ajouter son icône dans `Gadget/App/Resources/Assets.xcassets` et une ligne dans `Catalogue.swift`.
6. Ajouter son dossier aux chemins de `.github/workflows/gadget.yml`.

Attention aux noms : tous les gadgets sont compilés ensemble, deux types ne peuvent pas avoir le
même nom (d'où `SonarModel`, `SonarView` plutôt que `AppModel`, `ContentView`).

## Installer

Compilée sur GitHub (`.github/workflows/gadget.yml`) à chaque changement de `Gadget/`, `App/Sources/`,
`Packages/SleepCore/`, `Cine/`, `Sonar/`, `Telecommande/` ou `Shared/`, et publiée dans la source
SideStore commune (« Sommeil et Gadget »).

Gadget est une **nouvelle app** pour iOS : les réglages et la pellicule interne de l'app Ciné seule
ne la suivent pas (les photos, elles, sont dans l'app Photos). Les scans de Sonar non plus.
