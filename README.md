# Sommeil — suivi de nuit sur iPhone seul

App iPhone qui enregistre toute la nuit, écran verrouillé : mouvements à 100 Hz (pouls, respiration,
position), son, état de l'iPhone. Elle montre aussi l'activité du cœur **en direct**, téléphone posé
sur la poitrine. Depuis la version 0.2, plus besoin du PC ni du Blue Yeti.

**Ce n'est pas un appareil médical.**

## Où en est le projet

- **Fait (0.2)** : app autonome (PC et Blue Yeti retirés), nouvelle interface en onglets
  (Ce soir, Cœur, Nuits, Réglages), écran « Cœur en direct », installation par SideStore.
- **Fait (0.3)** : analyse de la nuit sur l'iPhone (mouvements, position, pouls, respiration au
  mouvement et au micro, pauses possibles, ronflements, endormissement, note sur 100), rapport
  avec chronologie et événements à réécouter, tendance des notes.
- **Ensuite** : vérification sur de vraies nuits, phases de sommeil estimées, réveil intelligent.

Le plan complet : fiche « Refonte de l'app Sommeil : iPhone seul ».

## Contenu

- `App/` : l'app iPhone (SwiftUI).
- `Packages/SleepCore/` : le cœur commun (format des fichiers, filtres, battements en direct, bilan),
  avec ses tests (simulations dont on connaît chaque battement).
- `FORMAT.md` : description exacte des fichiers enregistrés.
- `reference/` : les anciens programmes du PC (Python), gardés pour vérifier les calculs et le format.
- `scripts/source_sidestore.py` : fabrique la source SideStore publiée avec chaque version.
- `.github/workflows/compilation.yml` : compilation automatique sur un Mac de GitHub.

## Installer l'app

Mode d'emploi pas à pas : [INSTALLATION.md](INSTALLATION.md) (SideStore ; le PC ne sert qu'une fois).

À chaque modification, GitHub compile l'app et publie dans **Releases** :
- `Sommeil.ipa` : https://github.com/biliboy00000/sommeil-ios/releases/latest/download/Sommeil.ipa
- la source SideStore : https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json
