# Sommeil — enregistreur iPhone (v2 du projet SuiviSommeil)

App iPhone qui enregistre toute la nuit, téléphone attaché sur le thorax :
mouvements à 100 Hz (pour le pouls, la respiration, la position), son, état de l'iPhone.
L'analyse se fait ensuite sur le PC.

**Ce n'est pas un appareil médical.**

## Où en est le projet

- **Phase 1 (en cours)** : l'enregistreur seul. Test de placement, test guidé de 10 minutes,
  enregistrement de nuit écran verrouillé, bilan du matin, envoi au PC.
- Phase 2 : les algorithmes (pouls, variabilité, respiration, position, phases), sur de vraies données.
- Phase 3 : validation sur une nuit complète.

## Contenu

- `App/` : l'app iPhone (SwiftUI).
- `Packages/SleepCore/` : le cœur commun (format des fichiers, filtres, estimations rapides, bilan),
  avec ses tests.
- `pc/` : le récepteur Windows (`5_RECEVOIR_IPHONE.bat`) et la lecture des données en Python.
- `FORMAT.md` : description exacte des fichiers enregistrés.
- `.github/workflows/compilation.yml` : compilation automatique sur un Mac de GitHub.

## Installer l'app (sans Mac)

À chaque modification, GitHub compile l'app et publie `Sommeil.ipa` dans **Releases**.
Lien direct vers la dernière version :
https://github.com/biliboy00000/sommeil-ios/releases/latest/download/Sommeil.ipa

Paquet complet pour une première installation (app + fichiers du PC + mode d'emploi pas à pas) :
https://github.com/biliboy00000/sommeil-ios/releases/latest/download/SuiviSommeil_installation.zip

On l'installe avec **Sideloadly** sur le PC et un identifiant Apple gratuit. L'installation est
valable 7 jours ; l'app affiche sa date d'expiration et prévient avant une nuit si elle approche.
