# Toile

Navigateur pour iPhone, sur le moteur de Safari (WebKit, comme tous les navigateurs sur iPhone), avec :

- **Bloqueur de pubs et de traqueurs** : les listes d'uBlock (EasyList, EasyPrivacy, Liste FR, uBlock
  filters, uBlock filters – Privacy, Peter Lowe), converties pour le bloqueur de contenu de WebKit.
  Une page entière bloquée (adresse de pub connue) peut être ouverte quand même. Menu ⋯ › « Bloqueur
  sur ce site » pour le couper sur un site.
- **SponsorBlock** : saute les sponsors, intros, rappels d'abonnement… signalés sur sponsor.ajay.app,
  avec « Annuler ». Seul le début d'une empreinte de l'identifiant de la vidéo est envoyé.
- **YouTube** : pubs vidéo retirées des réponses de YouTube avant la lecture (et coupées, sautées si
  l'une passe quand même), lecture en arrière-plan (à l'essai), image dans l'image (menu ⋯).
- Onglets, onglets privés (rien n'est gardé), favoris, historique, téléchargements (Fichiers › Toile),
  recherche dans la page, version ordinateur. Recherche Google par défaut (Réglages).

## Comment c'est construit

| Fichier | Rôle |
|---|---|
| `App/Sources/Navigateur.swift` | Onglets, restauration, saisie de la barre d'adresse |
| `App/Sources/Onglet.swift` | Une page (WKWebView) : navigation, alertes, menus, téléchargements |
| `App/Sources/Bloqueur.swift` | Listes du bloqueur : compilation, mise à jour hebdomadaire |
| `App/Sources/Scripts.swift` | Les « extensions » : scripts YouTube et SponsorBlock |
| `App/Sources/SponsorBlock.swift` | API SponsorBlock (mode préfixe d'empreinte) |
| `filtres/convertir.py` | Listes d'uBlock → règles WebKit (sur GitHub) |
| `filtres/verifier.swift` | Compile les règles avec le vrai WebKit et retire celles qu'il refuse |

Les scripts tournent seulement sur YouTube. Celui de SponsorBlock est dans un monde isolé : la page ne
voit ni ses variables ni son canal vers l'app, et l'app vérifie que la demande vient bien de YouTube.

WebKit ne sait pas tout faire comme uBlock : les scriptlets (`##+js`), les filtres procéduraux
(`:has-text`…), `$redirect`, `$removeparam`, `$csp`… sont laissés de côté (le décompte est dans le
manifeste des listes).

## Compilation et listes

- `.github/workflows/toile.yml` : à chaque changement de `Toile/`, convertit et vérifie les listes, les met
  dans l'app, compile `Toile.ipa` et l'ajoute à la source SideStore « Sommeil et Gadget ».
- `.github/workflows/filtres.yml` : chaque lundi, refait les listes et les publie dans la version
  « filtres » du dépôt ; Toile les télécharge toute seule (une fois par semaine au plus).

Ouvrir un lien depuis un Raccourci : `toile://exemple.com`.
