# Anciens programmes du PC (référence)

Depuis la version 0.2, l'app Sommeil fonctionne sur l'iPhone seul : le récepteur Windows, le Blue Yeti
et le paquet d'installation pour le PC ne servent plus.

Ils restent ici pour deux raisons :
- `pc/lecture_iphone.py` et `pc/verifier_seance.py` lisent exactement le format des enregistrements
  (voir `FORMAT.md`) : ils servent à vérifier les calculs de l'app sur de vraies nuits ;
- leurs tests tournent à chaque compilation et contrôlent que le format ne change pas par erreur.
