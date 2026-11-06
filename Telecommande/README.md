# Télécommande

Gadget de l'app Gadget : piloter le PC depuis le téléphone (Wi-Fi de la maison), et faire sortir
**le son du PC sur le téléphone** d'un seul bouton.

- `serveur/` : le programme à lancer sur le PC (Windows), en Python.
- `App/Sources/` : le gadget iOS (intégré à Gadget, pas d'app seule).

## Sur le PC

1. Installer Python 3 (https://www.python.org/downloads/, cocher « Add python.exe to PATH »).
2. Double-cliquer sur `serveur/lancer-windows.bat`. La première fois, il installe ce qu'il faut (1 min).
3. Si Windows demande l'accès au réseau : **Autoriser** (réseau privé).
4. La fenêtre affiche un **QR code** : dans Gadget › Télécommande › « Scanner le QR code ».

La fenêtre doit rester ouverte ; la fermer arrête tout. Pour la lancer avec Windows : mettre un
raccourci de `lancer-windows.bat` dans le dossier `shell:startup` (Win+R › `shell:startup`).

La clé d'accès (dans `config.json`, transmise par le QR code) empêche les autres appareils du Wi-Fi
de se connecter. Supprimer `config.json` en crée une nouvelle (il faudra rescanner).

## Le bouton « Son : PC / Téléphone »

- **Téléphone** : le programme capture ce que le PC joue (bouclage WASAPI), coupe les haut-parleurs
  du PC et envoie le son au téléphone (48 kHz stéréo, ~1,5 Mbit/s). Le son continue écran verrouillé.
- **PC** : la capture s'arrête et le son du PC est rétabli comme avant.
- Si le téléphone se déconnecte, le son revient tout seul sur le PC.
- **Délai du son** (onglet Lecture) : 100 ms par défaut. Plus bas = mieux synchronisé avec la vidéo,
  plus haut = moins de coupures si le Wi-Fi est chargé.

## Fonctions

| Onglet | Contenu |
|---|---|
| Pavé | 1 doigt = souris, toucher = clic, 2 doigts = défiler, toucher à 2 doigts = clic droit, appui long = glisser ; clavier en direct ; touches (⌫, ⏎, Échap, Tab, flèches, Alt+Tab, copier/coller) |
| Lecture | Lecture/pause, piste précédente/suivante, ±5 s, plein écran, sous-titres, muet, volume du PC (ou du téléphone quand le son y est), délai du son |
| Système | YouTube, Netflix, Google, adresse ou recherche ; verrouiller, écran noir, veille, redémarrer, éteindre (15 s pour annuler) ; vitesse de la souris ; oublier le PC |

## Tester sans PC Windows

```bash
cd serveur && pip install -r requirements.txt
TELECOMMANDE_SIMULATION=1 python3 serveur.py   # aucune action réelle, le son est un bip de test
```
