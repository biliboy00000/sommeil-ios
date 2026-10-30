# Installer Sommeil avec SideStore

L'app n'est pas sur l'App Store. Avec un identifiant Apple gratuit, Apple limite une installation
à 7 jours. **SideStore** la renouvelle depuis l'iPhone : l'ordinateur ne sert qu'une seule fois,
pour installer SideStore (environ 20 minutes).

## Ce qu'il faut

- L'iPhone, avec un code de verrouillage et le **mode développeur** activé
  (Réglages › Confidentialité et sécurité › Mode développeur ; déjà fait pour Sideloadly).
- Le PC Windows et le câble de l'iPhone, **une seule fois**.
- Ton identifiant Apple (gratuit).

## 1. Sur l'iPhone : LocalDevVPN

1. Installe **LocalDevVPN** depuis l'App Store (gratuit, fait par l'équipe de SideStore).
2. Ouvre-la, touche **Connect**, puis **Autoriser** quand iOS demande d'ajouter une configuration VPN.
   Ce « VPN » reste dans l'iPhone : rien ne sort sur internet.

## 2. Sur le PC : installer SideStore (une seule fois)

1. Installe **iTunes** depuis le site d'Apple (apple.com/itunes), pas depuis le Microsoft Store si possible.
2. Installe **iloader** : https://iloader.app (fichier `.msi` pour Windows).
3. Branche l'iPhone au PC, déverrouille-le et touche **Faire confiance**.
4. Ouvre iloader, connecte-toi avec ton identifiant Apple, choisis ton iPhone, puis installe **SideStore**.
   iloader place aussi sur l'iPhone le « fichier d'appairage » qui permet ensuite de se passer du PC.

## 3. Sur l'iPhone : premier lancement de SideStore

1. Réglages › Général › VPN et gestion de l'appareil › ton identifiant Apple › **Faire confiance**.
2. Ouvre LocalDevVPN et touche **Connect**.
3. Ouvre SideStore et connecte-toi avec le **même** identifiant Apple.
4. Onglet **My Apps** : touche le bouton **7 DAYS** à côté de SideStore (premier renouvellement).
   Si SideStore demande quoi faire des extensions, choisis de les **garder**.

Tu peux débrancher l'iPhone : le PC ne sert plus.

## 4. Installer Sommeil

Au choix :

- **Avec la source (mises à jour proposées toutes seules).** Dans SideStore, onglet **Sources**, touche
  **+** et colle ce lien :
  `https://github.com/biliboy00000/sommeil-ios/releases/latest/download/source.json`
  puis installe Sommeil depuis la source.
- **Avec le fichier.** Dans Safari, ouvre
  https://github.com/biliboy00000/sommeil-ios/releases/latest/download/Sommeil.ipa
  puis, dans SideStore › My Apps, touche **+** et choisis `Sommeil.ipa` dans Téléchargements.

LocalDevVPN doit être connecté pendant l'installation.

**À savoir :** SideStore installe l'app sous un identifiant légèrement différent de celui de Sideloadly.
L'ancienne app reste à côté jusqu'à son expiration, avec ses enregistrements. Les nuits du 11, 12 et
22 octobre sont déjà sur le PC. Pour une autre nuit restée sur l'iPhone, ouvre-la dans l'ancienne app et
touche « Partager » avant de la supprimer.

## 4 bis. Installer Ciné (appareil photo, facultatif)

La même source propose aussi **Ciné**, l'appareil photo au rendu pellicule (voir `Cine/README.md`).
Dans SideStore › Sources › « Sommeil et Ciné », installe Ciné. Ou le fichier `Cine.ipa` de la
dernière version « Ciné 1.0.N » dans la page Releases du dépôt.

Un identifiant Apple gratuit permet **3 apps actives**, SideStore compris : SideStore + Sommeil + Ciné.
Supprime d'abord l'ancienne Sommeil installée avec Sideloadly si elle est encore là.

## 5. Tous les 7 jours : renouveler

1. LocalDevVPN › **Connect**.
2. SideStore › My Apps › **Refresh All**.

L'app Sommeil affiche la date d'expiration (onglet « Ce soir », tuile Installation) et prévient avant
une nuit si l'installation expire avant le réveil. Pour ne plus y penser : app **Raccourcis** ›
Automatisation › tous les jours à midi › action SideStore « Refresh All Apps ».

## Si quelque chose bloque

- **SideStore n'arrive plus à renouveler après une mise à jour d'iOS** : le fichier d'appairage peut être à
  refaire. Rebranche l'iPhone au PC et relance iloader une fois.
- **« Maximum App ID limit »** : un identifiant gratuit permet 10 identifiants d'app par semaine
  (Sommeil en utilise 2 : l'app et son extension de notification ; Ciné en utilise 1). Attends quelques
  jours, ou retire l'extension quand SideStore le propose (le rappel du soir marche quand même, en
  ouvrant l'app).
- **« Maximum number of apps »** : 3 apps actives au plus avec un identifiant gratuit (SideStore compris).
